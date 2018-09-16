//
//  Account.swift
//  DataModel
//
//  Created by Brent Simmons on 7/1/17.
//  Copyright © 2017 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import Articles
import RSParser
import ArticlesDatabase
import RSWeb
import RSDatabase

public extension Notification.Name {

	public static let AccountRefreshDidBegin = Notification.Name(rawValue: "AccountRefreshDidBegin")
	public static let AccountRefreshDidFinish = Notification.Name(rawValue: "AccountRefreshDidFinish")
	public static let AccountRefreshProgressDidChange = Notification.Name(rawValue: "AccountRefreshProgressDidChange")
	public static let AccountDidDownloadArticles = Notification.Name(rawValue: "AccountDidDownloadArticles")
	
	public static let StatusesDidChange = Notification.Name(rawValue: "StatusesDidChange")
}

public enum AccountType: Int {

	// Raw values should not change since they’re stored on disk.
	case onMyMac = 1
	case feedly = 16
	case feedbin = 17
	case feedWrangler = 18
	case newsBlur = 19
	// TODO: more
}

public final class Account: DisplayNameProvider, UnreadCountProvider, Container, Hashable {

    public struct UserInfoKey {
		public static let newArticles = "newArticles" // AccountDidDownloadArticles
		public static let updatedArticles = "updatedArticles" // AccountDidDownloadArticles
		public static let statuses = "statuses" // StatusesDidChange
		public static let articles = "articles" // StatusesDidChange
		public static let feeds = "feeds" // AccountDidDownloadArticles, StatusesDidChange
	}

	public let accountID: String
	public let type: AccountType
	public var nameForDisplay = ""
	public var children = [AnyObject]()
	var urlToFeedDictionary = [String: Feed]()
	var idToFeedDictionary = [String: Feed]()
	let settingsFile: String
	let dataFolder: String
	let database: ArticlesDatabase
	let delegate: AccountDelegate
	var username: String?
	static let saveQueue = CoalescingQueue(name: "Account Save Queue", interval: 1.0)

	private let settingsODB: ODB
	private let settingsTable: ODBTable
	private let feedsPath: ODBPath
	private let feedsTable: ODBTable

	private var unreadCounts = [String: Int]() // [feedID: Int]
	private let opmlFilePath: String

	private struct SettingsKey {
		static let unreadCount = "unreadCount"
	}
	public var dirty = false {
		didSet {
			if dirty && !refreshInProgress {
				queueSaveToDiskIfNeeded()
			}
		}
	}

    public var unreadCount = 0 {
        didSet {
            if unreadCount != oldValue {
                postUnreadCountDidChangeNotification()
            }
        }
    }
    
	var refreshInProgress = false {
		didSet {
			if refreshInProgress != oldValue {
				if refreshInProgress {
					NotificationCenter.default.post(name: .AccountRefreshDidBegin, object: self)
				}
				else {
					NotificationCenter.default.post(name: .AccountRefreshDidFinish, object: self)
					queueSaveToDiskIfNeeded()
				}
			}
		}
	}

	var refreshProgress: DownloadProgress {
		return delegate.refreshProgress
	}
	
	var supportsSubFolders: Bool {
		return delegate.supportsSubFolders
	}
	
	init?(dataFolder: String, settingsFile: String, type: AccountType, accountID: String) {
		
		// TODO: support various syncing systems.
		precondition(type == .onMyMac)
		self.delegate = LocalAccountDelegate()

		self.accountID = accountID
		self.type = type
		self.settingsFile = settingsFile
		self.dataFolder = dataFolder

		self.opmlFilePath = (dataFolder as NSString).appendingPathComponent("Subscriptions.opml")

		let databaseFilePath = (dataFolder as NSString).appendingPathComponent("DB.sqlite3")
		self.database = ArticlesDatabase(databaseFilePath: databaseFilePath, accountID: accountID)

		let settingsODBFilePath = (dataFolder as NSString).appendingPathComponent("Settings.odb")
		self.settingsODB = ODB(filepath: settingsODBFilePath)
		self.settingsODB.vacuum()
		let settingsPath = ODBPath.path(["settings"])
		self.settingsTable = settingsODB.ensureTable(settingsPath)!
		self.feedsPath = ODBPath.path(["feeds"])
		self.feedsTable = settingsODB.ensureTable(self.feedsPath)!

		NotificationCenter.default.addObserver(self, selector: #selector(downloadProgressDidChange(_:)), name: .DownloadProgressDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(batchUpdateDidPerform(_:)), name: .BatchUpdateDidPerform, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange(_:)), name: .DisplayNameDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(childrenDidChange(_:)), name: .ChildrenDidChange, object: nil)

		pullObjectsFromDisk()
		
		DispatchQueue.main.async {
			self.fetchAllUnreadCounts()
		}

		self.delegate.accountDidInitialize(self)
	}
	
	// MARK: - API

	public func refreshAll() {

		delegate.refreshAll(for: self)
	}

	public func update(_ feed: Feed, with parsedFeed: ParsedFeed, _ completion: @escaping RSVoidCompletionBlock) {

		feed.takeSettings(from: parsedFeed)

		database.update(feedID: feed.feedID, parsedFeed: parsedFeed) { (newArticles, updatedArticles) in

			var userInfo = [String: Any]()
			if let newArticles = newArticles, !newArticles.isEmpty {
				self.updateUnreadCounts(for: Set([feed]))
				userInfo[UserInfoKey.newArticles] = newArticles
			}
			if let updatedArticles = updatedArticles, !updatedArticles.isEmpty {
				userInfo[UserInfoKey.updatedArticles] = updatedArticles
			}
			userInfo[UserInfoKey.feeds] = Set([feed])

			completion()

			NotificationCenter.default.post(name: .AccountDidDownloadArticles, object: self, userInfo: userInfo)
		}
	}

	public func markArticles(_ articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool) -> Set<Article>? {

		// Returns set of Articles whose statuses did change.

		guard let updatedStatuses = database.mark(articles, statusKey: statusKey, flag: flag) else {
			return nil
		}
		
		let updatedArticleIDs = updatedStatuses.articleIDs()
		let updatedArticles = Set(articles.filter{ updatedArticleIDs.contains($0.articleID) })
        
        noteStatusesForArticlesDidChange(updatedArticles)
		return updatedArticles
	}

	@discardableResult
	public func ensureFolder(with name: String) -> Folder? {

		// TODO: support subfolders, maybe, some day

		if name.isEmpty {
			return nil
		}

		if let folder = existingFolder(with: name) {
			return folder
		}

		let folder = Folder(account: self, name: name)
		children += [folder]
		dirty = true

		postChildrenDidChangeNotification()
		return folder
	}

	public func ensureFolder(withFolderNames folderNames: [String]) -> Folder? {

		// TODO: support subfolders, maybe, some day.
		// Since we don’t, just take the last name and make sure there’s a Folder.

		guard let folderName = folderNames.last else {
			return nil
		}
		return ensureFolder(with: folderName)
	}

	public func canAddFeed(_ feed: Feed, to folder: Folder?) -> Bool {

		// If folder is nil, then it should go at the top level.
		// The same feed in multiple folders is allowed.
		// But the same feed can’t appear twice in the same folder
		// (or at the top level).

		return true // TODO
	}

	@discardableResult
	public func addFeed(_ feed: Feed, to folder: Folder?) -> Bool {

		// Return false if it couldn’t be added.
		// If it already existed in that folder, return true.

		var didAddFeed = false
		let uniquedFeed = existingFeed(with: feed.feedID) ?? feed
		
		if let folder = folder {
			didAddFeed = folder.addFeed(uniquedFeed)
		}
		else {
			if !topLevelObjectsContainsFeed(uniquedFeed) {
				children += [uniquedFeed]
				postChildrenDidChangeNotification()
			}
			didAddFeed = true
		}

		if didAddFeed {
			addToFeedDictionaries(uniquedFeed)
			dirty = true
		}
		
		return didAddFeed
	}

	public func createFeed(with name: String?, editedName: String?, url: String) -> Feed? {
		
		// For syncing, this may need to be an async method with a callback,
		// since it will likely need to call the server.
		
		if let feed = existingFeed(withURL: url) {
			if let editedName = editedName {
				feed.editedName = editedName
			}
			return feed
		}
		
		let feed = Feed(account: self, url: url, feedID: url)
		feed.name = name
		feed.editedName = editedName
        
		return feed
	}
	
	public func canAddFolder(_ folder: Folder, to containingFolder: Folder?) -> Bool {

		return false // TODO
	}

	@discardableResult
	public func addFolder(_ folder: Folder, to parentFolder: Folder?) -> Bool {

		// TODO: support subfolders, maybe, some day, if one of the sync systems
		// supports subfolders. But, for now, parentFolder is ignored.

		if objectIsChild(folder) {
			return true
		}
		children += [folder]
		postChildrenDidChangeNotification()
		rebuildFeedDictionaries()
		return true
	}

 	public func importOPML(_ opmlDocument: RSOPMLDocument) {

		guard let children = opmlDocument.children else {
			return
		}
		rebuildFeedDictionaries()
		importOPMLItems(children, parentFolder: nil)
		saveToDisk()

		DispatchQueue.main.async {
			self.refreshAll()
		}
	}

	public func updateUnreadCounts(for feeds: Set<Feed>) {

		if feeds.isEmpty {
			return
		}
		
		database.fetchUnreadCounts(for: feeds.feedIDs()) { (unreadCountDictionary) in

			for feed in feeds {
				if let unreadCount = unreadCountDictionary[feed.feedID] {
					feed.unreadCount = unreadCount
				}
			}
		}
	}

	public func fetchArticles(for feed: Feed) -> Set<Article> {

		let articles = database.fetchArticles(for: feed.feedID)
		validateUnreadCount(feed, articles)
		return articles
	}

	public func fetchUnreadArticles(for feed: Feed) -> Set<Article> {

		let articles = database.fetchUnreadArticles(for: Set([feed.feedID]))
		validateUnreadCount(feed, articles)
		return articles
	}

	public func fetchUnreadArticles() -> Set<Article> {

		return fetchUnreadArticles(forContainer: self)
	}

	public func fetchArticles(folder: Folder) -> Set<Article> {

		return fetchUnreadArticles(forContainer: folder)
	}

	public func fetchUnreadArticles(forContainer container: Container) -> Set<Article> {

		let feeds = container.flattenedFeeds()
		let articles = database.fetchUnreadArticles(for: feeds.feedIDs())

		// Validate unread counts. This was the site of a performance slowdown:
		// it was calling going through the entire list of articles once per feed:
		// feeds.forEach { validateUnreadCount($0, articles) }
		// Now we loop through articles exactly once. This makes a huge difference.

		var unreadCountStorage = [String: Int]() // [FeedID: Int]
		articles.forEach { (article) in
			precondition(!article.status.read)
			unreadCountStorage[article.feedID, default: 0] += 1
		}
		feeds.forEach { (feed) in
			let unreadCount = unreadCountStorage[feed.feedID, default: 0]
			feed.unreadCount = unreadCount
		}

		return articles
	}

	public func fetchTodayArticles() -> Set<Article> {

		return database.fetchTodayArticles(for: flattenedFeeds().feedIDs())
	}

	public func fetchStarredArticles() -> Set<Article> {

		return database.fetchStarredArticles(for: flattenedFeeds().feedIDs())
	}

	private func validateUnreadCount(_ feed: Feed, _ articles: Set<Article>) {

		// articles must contain all the unread articles for the feed.
		// The unread number should match the feed’s unread count.

		let feedUnreadCount = articles.reduce(0) { (result, article) -> Int in
			if article.feed == feed && !article.status.read {
				return result + 1
			}
			return result
		}

		feed.unreadCount = feedUnreadCount
	}

	public func fetchUnreadCountForToday(_ callback: @escaping (Int) -> Void) {

		let startOfToday = NSCalendar.startOfToday()
		database.fetchUnreadCount(for: flattenedFeeds().feedIDs(), since: startOfToday, callback: callback)
	}

	public func fetchUnreadCountForStarredArticles(_ callback: @escaping (Int) -> Void) {

		database.fetchStarredAndUnreadCount(for: flattenedFeeds().feedIDs(), callback: callback)
	}

	public func markEverywhereAsRead() {

		// Does not support undo.

		database.markEverywhereAsRead()
		flattenedFeeds().forEach { $0.unreadCount = 0 }		
	}

	public func opmlDocument() -> String {
		let escapedTitle = nameForDisplay.rs_stringByEscapingSpecialXMLCharacters()
		let openingText =
		"""
		<?xml version="1.0" encoding="UTF-8"?>
		<!-- OPML generated by NetNewsWire -->
		<opml version="1.1">
		<head>
		<title>\(escapedTitle)</title>
		</head>
		<body>

		"""

		let middleText = OPMLString(indentLevel: 0)

		let closingText =
		"""
				</body>
			</opml>
			"""

		let opml = openingText + middleText + closingText
		return opml
	}

	public func unreadCount(for feed: Feed) -> Int {
		return unreadCounts[feed.feedID] ?? 0
	}

	public func setUnreadCount(_ unreadCount: Int, for feed: Feed) {
		unreadCounts[feed.feedID] = unreadCount
	}

	// MARK: - Debug

	public func debugDropConditionalGetInfo() {

		#if DEBUG
			flattenedFeeds().forEach{ $0.debugDropConditionalGetInfo() }
		#endif
	}

	// MARK: - Notifications

	@objc func downloadProgressDidChange(_ note: Notification) {

		guard let noteObject = note.object as? DownloadProgress, noteObject === refreshProgress else {
			return
		}

		refreshInProgress = refreshProgress.numberRemaining > 0
		NotificationCenter.default.post(name: .AccountRefreshProgressDidChange, object: self)
	}
	
	@objc func unreadCountDidChange(_ note: Notification) {

		// Update the unread count if it’s a direct child.

		if let object = note.object, objectIsChild(object as AnyObject) {
			updateUnreadCount()
		}
	}
    
    @objc func batchUpdateDidPerform(_ note: Notification) {

		rebuildFeedDictionaries()
        updateUnreadCount()
    }

	@objc func childrenDidChange(_ note: Notification) {

		guard let object = note.object else {
			return
		}
		if let account = object as? Account, account === self {
			dirty = true
		}
		if let folder = object as? Folder, folder.account === self {
			dirty = true
		}
	}

	@objc func displayNameDidChange(_ note: Notification) {

		if let folder = note.object as? Folder, folder.account === self {
			dirty = true
		}
	}

	@objc func saveToDiskIfNeeded() {

		if dirty {
			saveToDisk()
		}
	}

	// MARK: - Hashable

	public func hash(into hasher: inout Hasher) {
		hasher.combine(accountID)
	}

	// MARK: - Equatable

	public class func ==(lhs: Account, rhs: Account) -> Bool {

		return lhs === rhs
	}
}


// MARK: - Disk (Public)

extension Account {

	func objects(with diskObjects: [[String: Any]]) -> [AnyObject] {

		return diskObjects.compactMap { object(with: $0) }
	}

	func settingsTableForFeed(feedID: String) -> ODBRawValueTable? {
		let feedPath = feedsPath + feedID
		let table = settingsODB.ensureTable(feedPath)
		return table?.rawValueTable
	}
}

// MARK: - Disk (Private)

private extension Account {
	
	struct Key {
		static let children = "children"
		static let userInfo = "userInfo"
		static let unreadCount = "unreadCount"
	}

	func queueSaveToDiskIfNeeded() {

		Account.saveQueue.add(self, #selector(saveToDiskIfNeeded))
	}

	func object(with diskObject: [String: Any]) -> AnyObject? {

		if Feed.isFeedDictionary(diskObject) {
			return Feed(account: self, dictionary: diskObject)
		}
		return Folder(account: self, dictionary: diskObject)
	}

	func pullObjectsFromDisk() {

		// 9/16/2018: Turning a corner — we used to store data in a plist file,
		// but now we’re switching over to OPML. Read the plist file one last time,
		// then rename it so we never read from it again.

		if FileManager.default.fileExists(atPath: settingsFile) {
			// Old code for reading in plist file.
			let settingsFileURL = URL(fileURLWithPath: settingsFile)
			guard let d = NSDictionary(contentsOf: settingsFileURL) as? [String: Any] else {
				return
			}
			guard let childrenArray = d[Key.children] as? [[String: Any]] else {
				return
			}
			children = objects(with: childrenArray)
			rebuildFeedDictionaries()

			let userInfo = d[Key.userInfo] as? NSDictionary
			delegate.update(account: self, withUserInfo: userInfo)

			// Rename plist file so we don’t see it next time.
			let renamedFilePath = (dataFolder as NSString).appendingPathComponent("AccountData-old.plist")
			do {
				try FileManager.default.moveItem(atPath: settingsFile, toPath: renamedFilePath)
			}
			catch {}

			dirty = true // Ensure OPML file will be written soon.
			return
		}

		importOPMLFile(path: opmlFilePath)
	}

	func importOPMLFile(path: String) {
		let opmlFileURL = URL(fileURLWithPath: path)
		var fileData: Data?
		do {
			fileData = try Data(contentsOf: opmlFileURL)
		} catch {
			NSApplication.shared.presentError(error)
			return
		}
		guard let opmlData = fileData else {
			return
		}

		let parserData = ParserData(url: opmlFileURL.absoluteString, data: opmlData)
		var opmlDocument: RSOPMLDocument?

		do {
			opmlDocument = try RSOPMLParser.parseOPML(with: parserData)
		} catch {
			NSApplication.shared.presentError(error)
			return
		}
		guard let parsedOPML = opmlDocument else {
			return
		}

		importOPML(parsedOPML)
	}

//	func diskDictionary() -> NSDictionary {
//
//		let diskObjects = children.compactMap { (object) -> [String: Any]? in
//
//			if let folder = object as? Folder {
//				return folder.dictionary
//			}
//			else if let feed = object as? Feed {
//				return feed.dictionary
//			}
//			return nil
//		}
//
//		var d = [String: Any]()
//		d[Key.children] = diskObjects as NSArray
//
//		if let userInfo = delegate.userInfo(for: self) {
//			d[Key.userInfo] = userInfo
//		}
//
//		return d as NSDictionary
//	}

	func saveToDisk() {

		dirty = false

//		let d = diskDictionary()
//		do {
//			try RSPlist.write(d, filePath: settingsFile)
//		}
//		catch let error as NSError {
//			NSApplication.shared.presentError(error)
//		}

		let opmlDocumentString = opmlDocument()
		do {
			let url = URL(fileURLWithPath: opmlFilePath)
			try opmlDocumentString.write(to: url, atomically: true, encoding: .utf8)
		}
		catch let error as NSError {
			NSApplication.shared.presentError(error)
		}
	}
}

// MARK: - Private

private extension Account {

	func rebuildFeedDictionaries() {

		var urlDictionary = [String: Feed]()
		var idDictionary = [String: Feed]()

		flattenedFeeds().forEach { (feed) in
			urlDictionary[feed.url] = feed
			idDictionary[feed.feedID] = feed
		}

		urlToFeedDictionary = urlDictionary
		idToFeedDictionary = idDictionary
	}

	func addToFeedDictionaries(_ feed: Feed) {

		urlToFeedDictionary[feed.url] = feed
		idToFeedDictionary[feed.feedID] = feed
	}

	func topLevelObjectsContainsFeed(_ feed: Feed) -> Bool {
		
		return children.contains(where: { (object) -> Bool in
			if let oneFeed = object as? Feed {
				if oneFeed.feedID == feed.feedID {
					return true
				}
			}
			return false
		})
	}

	func createFeed(with opmlFeedSpecifier: RSOPMLFeedSpecifier) -> Feed {

		let feed = Feed(account: self, url: opmlFeedSpecifier.feedURL, feedID: opmlFeedSpecifier.feedURL)
		feed.editedName = opmlFeedSpecifier.title
		return feed
	}

	func importOPMLItems(_ items: [RSOPMLItem], parentFolder: Folder?) {

		items.forEach { (item) in

			if let feedSpecifier = item.feedSpecifier {
				let feed = createFeed(with: feedSpecifier)
				addFeed(feed, to: parentFolder)
				return
			}

			guard item.isFolder, let itemChildren = item.children else {
				return
			}

			// TODO: possibly support sub folders.

			guard let folderName = item.titleFromAttributes else {
				// Folder doesn’t have a name, so it won’t be created, and its items will go one level up.
				importOPMLItems(itemChildren, parentFolder: parentFolder)
				return
			}

			if let folder = ensureFolder(with: folderName) {
				importOPMLItems(itemChildren, parentFolder: folder)
			}
		}
	}
    
    func updateUnreadCount() {

		unreadCount = calculateUnreadCount(flattenedFeeds())
    }
    
    func noteStatusesForArticlesDidChange(_ articles: Set<Article>) {
        
		let feeds = Set(articles.compactMap { $0.feed })
		let statuses = Set(articles.map { $0.status })
        
        // .UnreadCountDidChange notification will get sent to Folder and Account objects,
        // which will update their own unread counts.
        updateUnreadCounts(for: feeds)
        
        NotificationCenter.default.post(name: .StatusesDidChange, object: self, userInfo: [UserInfoKey.statuses: statuses, UserInfoKey.articles: articles, UserInfoKey.feeds: feeds])
    }

	func fetchAllUnreadCounts() {

		database.fetchAllNonZeroUnreadCounts { (unreadCountDictionary) in

			if unreadCountDictionary.isEmpty {
				return
			}

			self.flattenedFeeds().forEach{ (feed) in

				// When the unread count is zero, it won’t appear in unreadCountDictionary.

				if let unreadCount = unreadCountDictionary[feed.feedID] {
					feed.unreadCount = unreadCount
				}
				else {
					feed.unreadCount = 0
				}
			}
			self.updateUnreadCount()
		}
	}
}

// MARK: - Container Overrides

extension Account {

	public func existingFeed(withURL url: String) -> Feed? {

		return urlToFeedDictionary[url]
	}

	public func existingFeed(with feedID: String) -> Feed? {

		return idToFeedDictionary[feedID]
	}
}

// MARK: - OPMLRepresentable

extension Account: OPMLRepresentable {

	public func OPMLString(indentLevel: Int) -> String {

		var s = ""
		for oneObject in children {
			if let oneOPMLObject = oneObject as? OPMLRepresentable {
				s += oneOPMLObject.OPMLString(indentLevel: indentLevel + 1)
			}
		}
		return s
	}
}
