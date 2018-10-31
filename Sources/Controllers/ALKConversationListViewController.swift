//
//  ALKConversationListViewController.swift
//  
//
//  Created by Mukesh Thawani on 04/05/17.
//  Copyright © 2017 Applozic. All rights reserved.
//

import Foundation
import UIKit
import ContactsUI
import Applozic

enum SelectedItem: Equatable {
    case ContactId(String)
    case GroupId(NSNumber)
    
    static func ==(lhs: SelectedItem, rhs: SelectedItem) -> Bool {
        switch (lhs, rhs) {
        case let (.ContactId(a),   .ContactId(b)):
            return a == b
        case let (.GroupId(a), .GroupId(b)):
            return a.intValue == b.intValue
        default:
            return false
        }
    }
}

open class ALKConversationListViewController: ALKBaseViewController {

    var viewModel: ALKConversationListViewModel!

    // To check if coming from push notification
    var contactId: String?
    var channelKey: NSNumber?
    var searchClicked: Bool = false
    var selectedRows = [SelectedItem]()
    var isMultiSelectEnabled: Bool = false

    public var conversationViewControllerType = ALKConversationViewController.self

    fileprivate var tapToDismiss:UITapGestureRecognizer!
    fileprivate let searchController = UISearchController(searchResultsController: nil)
    fileprivate var searchActive : Bool = false
    fileprivate var searchFilteredChat:[Any] = []
    fileprivate var alMqttConversationService: ALMQTTConversationService!
    fileprivate var dbService: ALMessageDBService!
    fileprivate let activityIndicator = UIActivityIndicatorView(activityIndicatorStyle: UIActivityIndicatorViewStyle.gray)

    fileprivate var conversationViewController: ALKConversationViewController?

    fileprivate let tableView : UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.estimatedRowHeight = 75
        tv.rowHeight = 75
        tv.separatorStyle = .none
        tv.backgroundColor = UIColor.white
        tv.keyboardDismissMode = .onDrag
        return tv
    }()

    fileprivate lazy var searchBar: UISearchBar = {
        var bar = UISearchBar()
        bar.autocapitalizationType = .sentences
        return bar
    }()

    required public init() {
        super.init(nibName: nil, bundle: nil)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override func addObserver() {

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "newMessageNotification"), object: nil, queue: nil, using: {[weak self] notification in
            guard let weakSelf = self, let viewModel = weakSelf.viewModel else { return }
            let msgArray = notification.object as? [ALMessage]
            print("new notification received: ", msgArray?.first?.message)
            guard let list = notification.object as? [Any], !list.isEmpty else { return }
            viewModel.addMessages(messages: list)

        })


        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "pushNotification"), object: nil, queue: nil, using: {[weak self] notification in
            print("push notification received: ", notification.object)
            guard let weakSelf = self, let object = notification.object as? String else { return }
            let components = object.components(separatedBy: ":")
            var groupId: NSNumber? = nil
            var contactId: String? = nil
            if components.count > 1, let secondComponent = Int(components[1]) {
                let id = NSNumber(integerLiteral: secondComponent)
                groupId = id
            } else {
                contactId = object
            }
            let message = ALMessage()
            message.contactIds = contactId
            message.groupId = groupId
            let info = notification.userInfo
            let alertValue = info?["alertValue"]
            guard let updateUI = info?["updateUI"] as? Int else { return }
            if updateUI == Int(APP_STATE_ACTIVE.rawValue), weakSelf.isViewLoaded, (weakSelf.view.window != nil) {
                guard let alert = alertValue as? String else { return }
                let alertComponents = alert.components(separatedBy: ":")
                if alertComponents.count > 1 {
                    message.message = alertComponents[1]
                } else {
                    message.message = alertComponents.first
                }
                weakSelf.viewModel.addMessages(messages: [message])
            } else if updateUI == Int(APP_STATE_BACKGROUND.rawValue) {
                // Coming from background

                guard contactId != nil || groupId != nil else { return }
               weakSelf.launchChat(contactId: contactId, groupId: groupId)
            }
        })

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "reloadTable"), object: nil, queue: nil, using: {[weak self] notification in
            NSLog("Reloadtable notification received")

            guard let weakSelf = self, let list = notification.object as? [Any] else { return }
            weakSelf.viewModel.updateMessageList(messages: list)
        })

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "USER_DETAILS_UPDATE_CALL"), object: nil, queue: nil, using: {[weak self] notification in
            NSLog("update user detail notification received")

            guard let weakSelf = self, let userId = notification.object as? String else { return }
            print("update user detail")
            ALUserService.updateUserDetail(userId, withCompletion: {
                userDetail in
                guard let detail = userDetail else { return }
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "USER_DETAIL_OTHER_VC"), object: detail)
                weakSelf.tableView.reloadData()
            })
        })

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "UPDATE_CHANNEL_NAME"), object: nil, queue: nil, using: {[weak self] notification in
            NSLog("update group name notification received")
            guard let weakSelf = self, (weakSelf.view.window != nil) else { return }
            print("update group detail")
            weakSelf.tableView.reloadData()
        })
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.paymentResponse(_:)), name: NSNotification.Name(rawValue: "paymentResponse"), object: nil)
        
    }
    
    func paymentResponse(_ notification: NSNotification) {
        if let info = notification.userInfo, let cancelFlag = info["cancelFlag"]{
            openChat(info: info)
        }else {
            print("Payment Response is not good")
        }
    }
    
    public func openChat(info: [AnyHashable : Any]) {
//        let processPaymentMessage = ProcessPaymentMessage()
//        processPaymentMessage.sendPaymentMessage(paymentJSON: info)
        if let groupIdOptional = info["groupId"] as? String, let groupIdInt = Int(groupIdOptional) {
            let groupId = NSNumber(value:groupIdInt)
//            launchChat(contactId: nil, groupId: groupId)
            launchChat(contactId: nil, groupId: groupId, conversationId: nil, info: info)
        }else {
            let contactId = info["userId"] as? String
//            launchChat(contactId: contactId, groupId: nil)
            launchChat(contactId: contactId, groupId: nil, conversationId: nil, info: info)
        }
    }

    override func removeObserver() {
        if (alMqttConversationService) != nil {
            alMqttConversationService.unsubscribeToConversation()
        }
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "pushNotification"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "newMessageNotification"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "reloadTable"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "USER_DETAILS_UPDATE_CALL"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "UPDATE_CHANNEL_NAME"), object: nil)
         NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "paymentResponse"), object: nil)
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dbService = ALMessageDBService()
        dbService.delegate = self
        viewModel = ALKConversationListViewModel()
        viewModel.delegate = self
        activityIndicator.center = CGPoint(x: view.bounds.size.width/2, y: view.bounds.size.height/2)
        activityIndicator.color = UIColor.gray
        view.addSubview(activityIndicator)
        self.view.bringSubview(toFront: activityIndicator)
        viewModel.prepareController(dbService: dbService)
        self.edgesForExtendedLayout = []
    }

    override open func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        searchBar.delegate = self
        alMqttConversationService = ALMQTTConversationService.sharedInstance()
        alMqttConversationService.mqttConversationDelegate = self
        alMqttConversationService.subscribeToConversation()
    }

    override open func viewDidAppear(_ animated: Bool) {
        print("contact id: ", contactId as Any)
        if contactId != nil || channelKey != nil {
            print("contact id present")
            launchChat(contactId: contactId, groupId: channelKey)
            self.contactId = nil
            self.channelKey = nil
        }
    }

    override open func viewWillDisappear(_ animated: Bool) {
        if let text = searchBar.text, !text.isEmpty {
            searchBar.text = ""
        }
        searchClicked = false
        searchBar.endEditing(true)
        searchActive = false
        tableView.reloadData()
    }
    
    lazy var leftBarBackButtonItem: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(named: "backIcon", in: Bundle.applozic, compatibleWith: nil), style: .plain, target: self, action: #selector(self.customBackAction))
        return button
    }()
    
    lazy var leftBarDoneButtonItem: UIBarButtonItem = {
        let back = NSLocalizedString("DoneButton", value: SystemMessage.ButtonName.Done, comment: "")
        let button = UIBarButtonItem(title: "Done", style: .plain, target: self, action: #selector(self.customDoneAction))
        return button
    }()

    private func setupView() {

        title = NSLocalizedString("ConversationListVCTitle", value: SystemMessage.ChatList.title, comment: "")

        let rightBarButtonItem = UIBarButtonItem(image: UIImage(named: "searchIcon", in: Bundle.applozic, compatibleWith: nil), style: .plain, target: self, action: #selector(compose))
        navigationItem.rightBarButtonItem = rightBarButtonItem
        

        navigationItem.leftBarButtonItem = leftBarBackButtonItem

        #if DEVELOPMENT
            let indicator = UIActivityIndicatorView(activityIndicatorStyle: .white)
            indicator.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            indicator.hidesWhenStopped = true
            indicator.stopAnimating()
            let indicatorButton = UIBarButtonItem(customView: indicator)

            navigationItem.leftBarButtonItem = indicatorButton
        #endif
        view.addViewsForAutolayout(views: [tableView])

        tableView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true

        tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tableView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        self.automaticallyAdjustsScrollViewInsets = false
        tableView.register(ALKChatCell.self)

        let nib = UINib(nibName: "EmptyChatCell", bundle: Bundle.applozic)
        tableView.register(nib, forCellReuseIdentifier: "EmptyChatCell")
        tableView.estimatedRowHeight = 0
    }

    @objc public func launchChat(contactId: String?, groupId: NSNumber?, conversationId: NSNumber? = nil, info: [AnyHashable : Any]? = nil) {
        let alChannelService = ALChannelService()
        let alContactDbService = ALContactDBService()
        var title = ""
        if let key = groupId, let alChannel = alChannelService.getChannelByKey(key), let name = alChannel.name {
            title = name
        }
        else if let key = contactId,let alContact = alContactDbService.loadContact(byKey: "userId", value: key), let name = alContact.getDisplayName() {
            title = name
        }
        let noName = NSLocalizedString("NoNameMessage", value: SystemMessage.NoData.NoName, comment: "")
        title = title.isEmpty ? noName : title
        let convViewModel = ALKConversationViewModel(contactId: contactId, channelKey: groupId)
        let convService = ALConversationService()
        if let convId = conversationId, let convProxy = convService.getConversationByKey(convId) {
            convViewModel.conversationProxy = convProxy
        }
        let viewController = conversationViewControllerType.init()
        viewController.title = title
        viewController.viewModel = convViewModel
        conversationViewController = viewController
        
        self.navigationController?.pushViewController(viewController, animated: false)
        
        if let INFO = info {
            viewController.processPaymentMessage(info: INFO)
        }
        
    }

    func compose() {
        searchClicked = true
        tableView.reloadData()
    }

    func sync(message: ALMessage) {

        if let viewController = conversationViewController, viewController.viewModel.contactId == message.contactId,viewController.viewModel.channelKey == message.groupId {
            print("Contact id matched1")
            viewController.viewModel.addMessagesToList([message])
        }
        if let dbService = dbService {
            viewModel.prepareController(dbService: dbService)
        }
    }

    //MARK: - Handle keyboard
    override func hideKeyboard()
    {
        tapToDismiss = UITapGestureRecognizer(
            target: self,
            action: #selector(UIViewController.dismissKeyboard))
        view.addGestureRecognizer(tapToDismiss)
    }

    override func dismissKeyboard()
    {
        searchBar.endEditing(true)
        view.endEditing(true)
    }
    
    func customDoneAction() {
        isMultiSelectEnabled = false
        selectedRows.removeAll()
        tableView.reloadData()
        let rightBarButtonItem = UIBarButtonItem(image: UIImage(named: "searchIcon", in: Bundle.applozic, compatibleWith: nil), style: .plain, target: self, action: #selector(compose))
        navigationItem.rightBarButtonItem = rightBarButtonItem
        navigationItem.leftBarButtonItem = leftBarBackButtonItem
    }

    func customBackAction() {
        guard let nav = self.navigationController else { return }
        let dd = nav.popViewController(animated: true)
        if dd == nil {
            self.dismiss(animated: true, completion: nil)
        }
        BroadcastToIonic.sendBroadcast(name: "EXIT_BROADCAST")
    }
    
    func deleteMultipleChats() {
        let alert = UIAlertController(title: "Alert", message: "Are you sure you want to delete these conversations", preferredStyle: UIAlertControllerStyle.alert)
        alert.addAction(UIAlertAction(title: "Continue", style: UIAlertActionStyle.destructive, handler: { (action) in
            self.deleteMultipleChatsConfirmed()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertActionStyle.cancel, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }

    func deleteMultipleChatsConfirmed() {
        self.activityIndicator.startAnimating()
        var conversation = [ALMessage]()
        selectedRows.forEach { (currentItem) in
            self.viewModel.getChatList().forEach({ (chat) in
                if let message = chat as? ALMessage {
                    if message.groupId != nil{
                        
                        if currentItem == SelectedItem.GroupId(message.groupId){
                            conversation.append(message)
                        }
                    }else if let contId = message.contactIds, currentItem == SelectedItem.ContactId(contId){
                        conversation.append(message)
                    } else if let contId = message.contactId, currentItem == SelectedItem.ContactId(contId){
                        conversation.append(message)
                    }
                }
            })
        }
        selectedRows.removeAll()
        delete(conversationList: conversation, weakSelf: self) {
            self.activityIndicator.stopAnimating()
            self.selectedRows.removeAll()
            self.tableView.reloadData()
            self.isMultiSelectEnabled = false
            let rightBarButtonItem = UIBarButtonItem(image: UIImage(named: "searchIcon", in: Bundle.applozic, compatibleWith: nil), style: .plain, target: self, action: #selector(self.compose))
            self.navigationItem.rightBarButtonItem = rightBarButtonItem
            self.navigationItem.leftBarButtonItem = self.leftBarBackButtonItem
        }
    }
}

extension ALKConversationListViewController: UITableViewDelegate, UITableViewDataSource {
    open func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.numberOfSection()
    }

    open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if searchActive {
            return searchFilteredChat.count
        }
        return viewModel.numberOfRowsInSection(section: section)
    }

    open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        guard let chat = (searchActive ? searchFilteredChat[indexPath.row] as? ALMessage : viewModel.chatForRow(indexPath: indexPath)) else {
            return UITableViewCell()
        }
        let cell: ALKChatCell = tableView.dequeueReusableCell(forIndexPath: indexPath)
        cell.update(viewModel: chat, identity: nil)
//        cell.setComingSoonDelegate(delegate: self.view)
        cell.chatCellDelegate = self
        cell.tintColor = ALKConfiguration.init().customPrimary
        
        if isMultiSelectEnabled {
            cell.enableMultiSelect()
        } else {
            cell.disableMultiSelect()
        }
        
        let (_, check) = checkSelectedRowsContains(cell: cell)
        if check{
            cell.selectCheckBox()
        }else {
            cell.deselectCheckBox()
        }
        
        cell.tag = indexPath.row
        
        let gestureRecogniser = UILongPressGestureRecognizer(target: self, action: #selector(longPress))
        gestureRecogniser.minimumPressDuration = 1
        gestureRecogniser.cancelsTouchesInView = false
        cell.addGestureRecognizer(gestureRecogniser)
            
        return cell
    }
    
    func checkSelectedRowsContains(cell: ALKChatCell) -> (SelectedItem, Bool){
        if let channelKey = cell.viewModel?.channelKey{
            let currentItem = SelectedItem.GroupId(channelKey)
            if selectedRows.contains(currentItem) {
                return (currentItem, true)
            }else {
                return (currentItem, false)
            }
        }else {
            let contactId = cell.viewModel?.contactId
            let currentItem = SelectedItem.ContactId(contactId!)
            if selectedRows.contains(currentItem) {
                return (currentItem, true)
            }else {
                return (currentItem, false)
            }
        }
    }
    
    func hideSearchBarAndKeyboard() {
        searchClicked = false
        searchActive = false
        searchBar.isHidden = true
        searchBar.text = nil
        searchBar.endEditing(true)
    }
    
    func longPress(longPressGesture: UILongPressGestureRecognizer) {
        if longPressGesture.state == UIGestureRecognizerState.began {
            if searchClicked{
                hideSearchBarAndKeyboard()
            }
            isMultiSelectEnabled = true
            tableView.reloadData() // Necessary to enable all the checkboxes.
            
            let rightBarButtonItem = UIBarButtonItem(image: UIImage(named: "deleteIcon", in: Bundle.applozic, compatibleWith: nil), style: .plain, target: self, action: #selector(deleteMultipleChats))
            navigationItem.rightBarButtonItem = rightBarButtonItem
            navigationItem.leftBarButtonItem = leftBarDoneButtonItem
            if let cell = longPressGesture.view as? ALKChatCell {
                let (currentItem, _) = checkSelectedRowsContains(cell: cell)
                selectedRows.append(currentItem)
                cell.selectCheckBox()
            }
        }
    }
   
    open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isMultiSelectEnabled {
            let cell: ALKChatCell = tableView.cellForRow(at: indexPath) as! ALKChatCell
            let (currentItem, check) = checkSelectedRowsContains(cell: cell)
            if check{
                selectedRows.remove(object: currentItem)
                cell.deselectCheckBox()
            }else if selectedRows.count < 5 {
                selectedRows.append(currentItem)
                cell.selectCheckBox()
            }
            return
        }
        
        if searchActive {
            guard let chat = searchFilteredChat[indexPath.row] as? ALMessage else {return}
            let convViewModel = ALKConversationViewModel(contactId: chat.contactId, channelKey: chat.channelKey)
            let convService = ALConversationService()
            if let convId = chat.conversationId, let convProxy = convService.getConversationByKey(convId) {
                convViewModel.conversationProxy = convProxy
            }
            let viewController = conversationViewControllerType.init()
            viewController.title = chat.isGroupChat ? chat.groupName:chat.name
            viewController.viewModel = convViewModel
            conversationViewController = viewController
            self.navigationController?.pushViewController(viewController, animated: false)
        } else {
            guard let chat = viewModel.chatForRow(indexPath: indexPath) else { return }
            let convViewModel = ALKConversationViewModel(contactId: chat.contactId, channelKey: chat.channelKey)
            let convService = ALConversationService()
            if let convId = chat.conversationId, let convProxy = convService.getConversationByKey(convId) {
                convViewModel.conversationProxy = convProxy
            }
            let viewController = conversationViewControllerType.init()
            viewController.title = chat.isGroupChat ? chat.groupName:chat.name
            viewController.viewModel = convViewModel
            conversationViewController = viewController
            self.navigationController?.pushViewController(viewController, animated: false)
        }
    }

    open func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return searchBar
    }

    open func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if searchClicked{
            searchBar.isHidden = false
            return 50
        }else{
            return 0
        }
    }

    open func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {

        let view = tableView.dequeueReusableCell(withIdentifier: "EmptyChatCell")?.contentView
        if let tap = view?.gestureRecognizers?.first {
            view?.removeGestureRecognizer(tap)
        }
        let tap = UITapGestureRecognizer.init(target: self, action: #selector(compose))
        tap.numberOfTapsRequired = 1

        view?.addGestureRecognizer(tap)
        return view
    }

    open func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return viewModel.numberOfRowsInSection(section: 0) == 0 ? 325 : 0
    }

    open func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCellEditingStyle {
        return .none
    }

}

extension ALKConversationListViewController: UIScrollViewDelegate {
    open func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let  height = scrollView.frame.size.height
        let contentYoffset = scrollView.contentOffset.y
        let reloadDistance: CGFloat = 40.0 // Added this so that loading starts 40 points before the end
        let distanceFromBottom = scrollView.contentSize.height - contentYoffset - reloadDistance
        if distanceFromBottom < height {
            viewModel.fetchMoreMessages(dbService: dbService)
        }
    }
}

//MARK: ALMessagesDelegate
extension ALKConversationListViewController: ALMessagesDelegate {
    public func getMessagesArray(_ messagesArray: NSMutableArray!) {
        guard let messages = messagesArray as? [Any] else {
            return
        }
        viewModel.updateMessageList(messages: messages)
    }

    public func updateMessageList(_ messagesArray: NSMutableArray!) {
        print("updated message array: ", messagesArray)
    }
}

extension ALKConversationListViewController: ALKConversationListViewModelDelegate {

    open func startedLoading() {
        DispatchQueue.main.async {
            self.activityIndicator.startAnimating()
            self.tableView.isUserInteractionEnabled = false
        }
    }

    open func listUpdated() {
        DispatchQueue.main.async {
            self.tableView.reloadData()
            self.activityIndicator.stopAnimating()
            self.tableView.isUserInteractionEnabled = true
        }
    }

    open func rowUpdatedAt(position: Int) {
        tableView.reloadRows(at: [IndexPath(row: position, section: 0)], with: .automatic)
    }
}

extension ALKConversationListViewController: ALMQTTConversationDelegate {

    open func mqttDidConnected() {
        print("MQTT did connected")
    }

    open func updateUserDetail(_ userId: String!) {
        guard let userId = userId else { return }
        print("update user detail")

        ALUserService.updateUserDetail(userId, withCompletion: {
            userDetail in
            guard let detail = userDetail else { return }
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "USER_DETAIL_OTHER_VC"), object: detail)
            self.tableView.reloadData()
        })
    }
    
    func isNewMsgForOpenedChat(alMessage: ALMessage, vm: ALKConversationViewModel) -> Bool{
        if ((alMessage.groupId != nil && alMessage.groupId == vm.channelKey) || (alMessage.groupId == nil && vm.channelKey == nil && alMessage.contactId == vm.contactId)){
            return true
        }
        return false
    }

    open func syncCall(_ alMessage: ALMessage!, andMessageList messageArray: NSMutableArray!) {
        print("sync call: ", alMessage.description)
        guard let message = alMessage else { return }
        let viewController = conversationViewController
        if let vm = viewController?.viewModel, (vm.contactId != nil || vm.channelKey != nil), let visibleController = self.navigationController?.visibleViewController, visibleController.isKind(of: ALKConversationViewController.self), isNewMsgForOpenedChat(alMessage: alMessage, vm: vm) {

                viewModel.syncCall(viewController: viewController, message: message, isChatOpen: true)

            
        } else {
            var msg = message.message
            if msg == nil {
                msg = ""
            }
            let notificationView = ALNotificationView(alMessage: message, withAlertMessage: msg)
            notificationView?.showNativeNotificationWithcompletionHandler({
                response in
                self.launchChat(contactId: message.contactId, groupId: message.groupId, conversationId: message.conversationId)
            })
            if let visibleController = self.navigationController?.visibleViewController, visibleController.isKind(of: ALKConversationListViewController.self) {
                sync(message: alMessage)
            }
        }
        
        }

    open func delivered(_ messageKey: String!, contactId: String!, withStatus status: Int32) {
        viewModel.updateDeliveryReport(convVC: conversationViewController, messageKey: messageKey, contactId: contactId, status: status)
    }

    open func updateStatus(forContact contactId: String!, withStatus status: Int32) {
        viewModel.updateStatusReport(convVC: conversationViewController, forContact: contactId, status: status)
    }

    open func updateTypingStatus(_ applicationKey: String!, userId: String!, status: Bool) {
        print("Typing status is", status)

        guard let viewController = conversationViewController, let vm = viewController.viewModel else { return
        }
        guard (vm.contactId != nil && vm.contactId == userId) || vm.channelKey != nil else {
            return
        }
        print("Contact id matched")
        viewModel.updateTypingStatus(in: viewController, userId: userId, status: status)

    }

    open func reloadData(forUserBlockNotification userId: String!, andBlockFlag flag: Bool) {
        print("reload data")
    }

    open func updateLastSeen(atStatus alUserDetail: ALUserDetail!) {
        print("Last seen updated")
        viewModel.updateStatusFor(userDetail: alUserDetail)
    }
    
    open func mqttConnectionClosed() {
        NSLog("MQTT connection closed")
    }
}

extension ALKConversationListViewController: UISearchResultsUpdating,UISearchBarDelegate {

    func filterContentForSearchText(searchText: String, scope: String = "All") {
        searchFilteredChat = viewModel.getChatList().filter { (chatViewModel) -> Bool in
            guard let conversation = chatViewModel as? ALMessage else {
                return false
            }
            if conversation.isGroupChat {
                return conversation.groupName.lowercased().isCompose(of: searchText.lowercased())
            } else {
                return conversation.name.lowercased().isCompose(of: searchText.lowercased())
            }
        }
        self.tableView.reloadData()
    }

    public func updateSearchResults(for searchController: UISearchController) {
        filterContentForSearchText(searchText: searchController.searchBar.text!)
    }

    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {

        searchFilteredChat = viewModel.getChatList().filter { (chatViewModel) -> Bool in
            guard let conversation = chatViewModel as? ALMessage else {
                return false
            }
            if conversation.isGroupChat {
                return conversation.groupName.lowercased().isCompose(of: searchText.lowercased())
            } else {
                return conversation.name.lowercased().isCompose(of: searchText.lowercased())
            }
        }
        searchActive = !searchText.isEmpty
        self.tableView.reloadData()
    }

    public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {

        hideKeyboard()

        if(searchBar.text?.isEmpty)! {
            self.tableView.reloadData()
        }
    }

    public func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {

        view.removeGestureRecognizer(tapToDismiss)

        guard let text = searchBar.text else { return }

        if text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            if searchActive {
                searchActive = false
            }
            tableView.reloadData()
        }
    }

    public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchActive = false;
        self.tableView.reloadData()
    }

    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        self.tableView.reloadData()
    }

}

extension ALKConversationListViewController: ALKChatCellDelegate {

    func chatCell(cell: ALKChatCell, action: ALKChatCellAction, viewModel: ALKChatViewModelProtocol) {

        switch action {

        case .delete:

            guard let indexPath = self.tableView.indexPath(for: cell) else {return}
//            guard let account = ChatManager.shared.currentUser else {return}

            //TODO: Add activity indicator

            
            if searchActive {
                guard let conversation = searchFilteredChat[indexPath.row] as? ALMessage else {return}

                let prefixText = conversation.isGroupChat ? NSLocalizedString("DeleteGroupConversation", value: SystemMessage.Warning.DeleteGroupConversation, comment: "") : NSLocalizedString("DeleteSingleConversation", value: SystemMessage.Warning.DeleteSingleConversation, comment: "")
                let name = conversation.isGroupChat ? conversation.groupName : conversation.name
                let text = "\(prefixText) \(name)?"
                let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
                let cancelButton = UIAlertAction(title: NSLocalizedString("ButtonCancel", value: SystemMessage.ButtonName.Cancel, comment: ""), style: .cancel, handler: nil)
                let deleteButton = UIAlertAction(title: NSLocalizedString("ButtonRemove", value: SystemMessage.ButtonName.Remove, comment: ""), style: .destructive, handler: { [weak self] (alert) in
                    guard let weakSelf = self, ALDataNetworkConnection.checkDataNetworkAvailable() else { return }

                    if conversation.isGroupChat {
                        let channelService = ALChannelService()
                        if  channelService.isChannelLeft(conversation.groupId) {
                            weakSelf.dbService.deleteAllMessages(byContact: nil, orChannelKey: conversation.groupId)
                            ALChannelService.setUnreadCountZeroForGroupID(conversation.groupId)
                            weakSelf.searchFilteredChat.remove(at: indexPath.row)
                            weakSelf.viewModel.remove(message: conversation)
                            weakSelf.tableView.reloadData()
                        } else if ALChannelService.isChannelDeleted(conversation.groupId) {
                            let channelDbService = ALChannelDBService()
                            channelDbService.deleteChannel(conversation.groupId)
                            weakSelf.searchFilteredChat.remove(at: indexPath.row)
                            weakSelf.viewModel.remove(message: conversation)
                            weakSelf.tableView.reloadData()
                        } else {
                            channelService.leaveChannel(conversation.groupId, andUserId: ALUserDefaultsHandler.getUserId(), orClientChannelKey: nil, withCompletion: {
                                error in
                                ALMessageService.deleteMessageThread(nil, orChannelKey: conversation.groupId, withCompletion: {
                                    _,error in
                                    guard error == nil else { return }
                                    weakSelf.searchFilteredChat.remove(at: indexPath.row)
                                    weakSelf.viewModel.remove(message: conversation)
                                    weakSelf.tableView.reloadData()
                                    return
                                })
                            })
                        }
                    } else {
                        ALMessageService.deleteMessageThread(conversation.contactIds, orChannelKey: nil, withCompletion: {
                            _,error in
                            guard error == nil else { return }
                            weakSelf.viewModel.remove(message: conversation)
                            weakSelf.tableView.reloadData()
                        })
                    }
                })
                alert.addAction(cancelButton)
                alert.addAction(deleteButton)
                present(alert, animated: true, completion: nil)
            }
            else if let _ = self.viewModel.chatForRow(indexPath: indexPath), let conversation = self.viewModel.getChatList()[indexPath.row] as? ALMessage {

                let prefixText = conversation.isGroupChat ? NSLocalizedString("DeleteGroupConversation", value: SystemMessage.Warning.DeleteGroupConversation, comment: "") : NSLocalizedString("DeleteSingleConversation", value: SystemMessage.Warning.DeleteSingleConversation, comment: "")
                let name = conversation.isGroupChat ? conversation.groupName : conversation.name
                let text = "\(prefixText) \(name)?"
                let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
                let cancelBotton = UIAlertAction(title: NSLocalizedString("ButtonCancel", value: SystemMessage.ButtonName.Cancel, comment: ""), style: .cancel, handler: nil)
                let deleteBotton = UIAlertAction(title: NSLocalizedString("ButtonRemove", value: SystemMessage.ButtonName.Remove, comment: ""), style: .destructive, handler: { [weak self] (alert) in
                    guard let weakSelf = self else { return }
                    if conversation.isGroupChat {
                        let channelService = ALChannelService()
                        if  channelService.isChannelLeft(conversation.groupId) {
                            weakSelf.dbService.deleteAllMessages(byContact: nil, orChannelKey: conversation.groupId)
                            ALChannelService.setUnreadCountZeroForGroupID(conversation.groupId)
                            weakSelf.viewModel.remove(message: conversation)
                            weakSelf.tableView.reloadData()
                        } else if ALChannelService.isChannelDeleted(conversation.groupId) {
                            let channelDbService = ALChannelDBService()
                            channelDbService.deleteChannel(conversation.groupId)
                            weakSelf.viewModel.remove(message: conversation)
                            weakSelf.tableView.reloadData()
                        } else {
                            channelService.leaveChannel(conversation.groupId, andUserId: ALUserDefaultsHandler.getUserId(), orClientChannelKey: nil, withCompletion: {
                                error in
                                ALMessageService.deleteMessageThread(nil, orChannelKey: conversation.groupId, withCompletion: {
                                    _,error in
                                    guard error == nil else { return }
                                    weakSelf.viewModel.remove(message: conversation)
                                    weakSelf.tableView.reloadData()
                                    return
                                })
                            })
                        }
                    } else {
                        ALMessageService.deleteMessageThread(conversation.contactIds, orChannelKey: nil, withCompletion: {
                            _,error in
                            guard error == nil else { return }
                            weakSelf.viewModel.remove(message: conversation)
                            weakSelf.tableView.reloadData()
                        })
                    }
                })
                alert.addAction(cancelBotton)
                alert.addAction(deleteBotton)
                present(alert, animated: true, completion: nil)

            }
            break
        default:
            print("not present")
        }
    }
    
    func delete(conversationList: [ALMessage], weakSelf: ALKConversationListViewController, completionHandler: @escaping () -> Void ) {
        let group = DispatchGroup()
        for conversation in conversationList {
            group.enter()
            if conversation.groupId != nil {
                ALMessageService.deleteMessageThread(nil, orChannelKey: conversation.groupId, withCompletion: {
                    _,error in
                    guard error == nil else { return }
                    weakSelf.viewModel.remove(message: conversation)
                    self.tableView.reloadData()
                    group.leave()
                })
            } else {
                ALMessageService.deleteMessageThread(conversation.contactIds, orChannelKey:nil, withCompletion: {
                    _,error in
                    guard error == nil else { return }
                    weakSelf.viewModel.remove(message: conversation)
                    self.tableView.reloadData()
                    group.leave()
                })
            }
        }
        group.notify(queue: .main){
            completionHandler()
        }
    }
}

