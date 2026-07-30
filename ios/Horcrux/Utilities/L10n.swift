import Foundation

// swiftlint:disable type_body_length file_length

/// Type-safe localization constants.
enum L10n {

    // MARK: - Common

    enum Common {
        static let ok = NSLocalizedString("common.ok", comment: "")
        static let cancel = NSLocalizedString("common.cancel", comment: "")
        static let error = NSLocalizedString("common.error", comment: "")
        static let done = NSLocalizedString("common.done", comment: "")
        static let retry = NSLocalizedString("common.retry", comment: "")
        static let delete = NSLocalizedString("common.delete", comment: "")
        static let copy = NSLocalizedString("common.copy", comment: "")
        static let copied = NSLocalizedString("common.copied", comment: "")
        static let next = NSLocalizedString("common.next", comment: "")
        static let pin = NSLocalizedString("common.pin", comment: "")
        static let test = NSLocalizedString("common.test", comment: "")
        static let save = NSLocalizedString("common.save", comment: "")
        static let close = NSLocalizedString("common.close", comment: "")
        static let hide = NSLocalizedString("common.hide", comment: "")
        static let unhide = NSLocalizedString("common.unhide", comment: "")
        static let rename = NSLocalizedString("common.rename", comment: "")
        static let max = NSLocalizedString("common.max", comment: "")
        static let expand = NSLocalizedString("common.expand", comment: "")
        static let collapse = NSLocalizedString("common.collapse", comment: "")
        static let moreInfo = NSLocalizedString("common.moreInfo", comment: "")
        static let tapForDetails = NSLocalizedString("common.tapForDetails", comment: "")
    }

    // MARK: - JoinSigning

    enum JoinSigning {
        static let title = NSLocalizedString("joinSigning.title", comment: "")
        static let intro = NSLocalizedString("joinSigning.intro", comment: "")
        static let introHint = NSLocalizedString("joinSigning.introHint", comment: "")
        static let joinButton = NSLocalizedString("joinSigning.joinButton", comment: "")
        static let waitingForRequest = NSLocalizedString("joinSigning.waitingForRequest", comment: "")
        static let waitingForRequestHint = NSLocalizedString("joinSigning.waitingForRequestHint", comment: "")
        static let reviewTitle = NSLocalizedString("joinSigning.reviewTitle", comment: "")
        static let wallet = NSLocalizedString("joinSigning.wallet", comment: "")
        static let walletFingerprint = NSLocalizedString("joinSigning.walletFingerprint", comment: "")
        static let fromAddress = NSLocalizedString("joinSigning.fromAddress", comment: "")
        static let tokenContract = NSLocalizedString("joinSigning.tokenContract", comment: "")
        static let recipient = NSLocalizedString("joinSigning.recipient", comment: "")
        static let amount = NSLocalizedString("joinSigning.amount", comment: "")
        static let verifyWarning = NSLocalizedString("joinSigning.verifyWarning", comment: "")
        static let approve = NSLocalizedString("joinSigning.approve", comment: "")
        static let reject = NSLocalizedString("joinSigning.reject", comment: "")
        static let unmatchedTitle = NSLocalizedString("joinSigning.unmatchedTitle", comment: "")
        static let homeButton = NSLocalizedString("joinSigning.homeButton", comment: "")
        static let scanButton = NSLocalizedString("joinSigning.scanButton", comment: "")
        static let scannedInvalid = NSLocalizedString("joinSigning.scannedInvalid", comment: "")
        static let nearbyDevices = NSLocalizedString("joinSigning.nearbyDevices", comment: "")
        static let nearbySearching = NSLocalizedString("joinSigning.nearbySearching", comment: "")
        static func fromDevice(_ name: String) -> String {
            String(format: NSLocalizedString("joinSigning.fromDevice", comment: ""), name)
        }
        static func unmatchedBody(_ gpkPrefix: String) -> String {
            String(format: NSLocalizedString("joinSigning.unmatchedBody", comment: ""), gpkPrefix)
        }
    }

    // MARK: - Decoded Call (audit finding C4)

    enum DecodedCall {
        static let titleNativeTransfer = NSLocalizedString("decodedCall.title.nativeTransfer", comment: "")
        static let titleErc20Transfer = NSLocalizedString("decodedCall.title.erc20Transfer", comment: "")
        static let titleErc20TransferFrom = NSLocalizedString("decodedCall.title.erc20TransferFrom", comment: "")
        static let titleApprove = NSLocalizedString("decodedCall.title.approve", comment: "")
        static let titleApproveUnlimited = NSLocalizedString("decodedCall.title.approveUnlimited", comment: "")
        static let titleSetApprovalForAllTrue = NSLocalizedString("decodedCall.title.setApprovalForAllTrue", comment: "")
        static let titleSetApprovalForAllFalse = NSLocalizedString("decodedCall.title.setApprovalForAllFalse", comment: "")
        static let titleUnknown = NSLocalizedString("decodedCall.title.unknown", comment: "")

        static let fieldKind = NSLocalizedString("decodedCall.field.kind", comment: "")
        static let fieldFrom = NSLocalizedString("decodedCall.field.from", comment: "")
        static let fieldTo = NSLocalizedString("decodedCall.field.to", comment: "")
        static let fieldSpender = NSLocalizedString("decodedCall.field.spender", comment: "")
        static let fieldOperator = NSLocalizedString("decodedCall.field.operator", comment: "")
        static let fieldApproved = NSLocalizedString("decodedCall.field.approved", comment: "")
        static let fieldAmountRaw = NSLocalizedString("decodedCall.field.amountRaw", comment: "")
        static let fieldSelector = NSLocalizedString("decodedCall.field.selector", comment: "")
        static let fieldPayloadSize = NSLocalizedString("decodedCall.field.payloadSize", comment: "")

        static let amountUnlimited = NSLocalizedString("decodedCall.amount.unlimited", comment: "")
        static let approvedYes = NSLocalizedString("decodedCall.approved.yes", comment: "")
        static let approvedNo = NSLocalizedString("decodedCall.approved.no", comment: "")

        static let warnApprove = NSLocalizedString("decodedCall.warn.approve", comment: "")
        static let warnApproveUnlimited = NSLocalizedString("decodedCall.warn.approveUnlimited", comment: "")
        static let warnSetApprovalForAll = NSLocalizedString("decodedCall.warn.setApprovalForAll", comment: "")
        static let warnTransferFrom = NSLocalizedString("decodedCall.warn.transferFrom", comment: "")
        static let warnUnknown = NSLocalizedString("decodedCall.warn.unknown", comment: "")

        static let consentUnlimitedApprove = NSLocalizedString("decodedCall.consent.unlimitedApprove", comment: "")
        static let consentSetApprovalForAll = NSLocalizedString("decodedCall.consent.setApprovalForAll", comment: "")
    }

    // MARK: - App

    enum App {
        static let contentHidden = NSLocalizedString("app.contentHidden", comment: "")
        static let securityViolation = NSLocalizedString("app.securityViolation", comment: "")
        static let exitApp = NSLocalizedString("app.exitApp", comment: "")
        static let debuggerDetected = NSLocalizedString("app.debuggerDetected", comment: "")
        static let securityWarning = NSLocalizedString("app.securityWarning", comment: "")
        static let understandRisk = NSLocalizedString("app.understandRisk", comment: "")
        static let deviceCompromised = NSLocalizedString("app.deviceCompromised", comment: "")
        static let deepLinkJoinTitle = NSLocalizedString("app.deepLinkJoinTitle", comment: "")
        static let deepLinkJoinMessage = NSLocalizedString("app.deepLinkJoinMessage", comment: "")
        static let deepLinkJoinContinue = NSLocalizedString("app.deepLinkJoinContinue", comment: "")
    }

    // MARK: - Tabs

    enum Tab {
        static let wallet = NSLocalizedString("tab.wallet", comment: "")
        static let vault = NSLocalizedString("tab.vault", comment: "")
        static let shards = NSLocalizedString("tab.shards", comment: "")
        static let approvals = NSLocalizedString("tab.approvals", comment: "")
        static let settings = NSLocalizedString("tab.settings", comment: "")
    }

    enum Approvals {
        static let navTitle = NSLocalizedString("approvals.navTitle", comment: "")
        static let pendingSection = NSLocalizedString("approvals.pendingSection", comment: "")
        static let staleSection = NSLocalizedString("approvals.staleSection", comment: "")
        static let recentSection = NSLocalizedString("approvals.recentSection", comment: "")
        static let emptyTitle = NSLocalizedString("approvals.emptyTitle", comment: "")
        static let emptyMessage = NSLocalizedString("approvals.emptyMessage", comment: "")
        static let statusPending = NSLocalizedString("approvals.statusPending", comment: "")
        static let statusApproved = NSLocalizedString("approvals.statusApproved", comment: "")
        static let statusRejected = NSLocalizedString("approvals.statusRejected", comment: "")
        static let statusExpired = NSLocalizedString("approvals.statusExpired", comment: "")
        static let actionDismiss = NSLocalizedString("approvals.actionDismiss", comment: "")
        static let actionReject = NSLocalizedString("approvals.actionReject", comment: "")
        static let actionClearHistory = NSLocalizedString("approvals.actionClearHistory", comment: "")
        static let fromInitiator = NSLocalizedString("approvals.fromInitiator", comment: "")
        static let saveForLater = NSLocalizedString("approvals.saveForLater", comment: "")
        static let staleWarning = NSLocalizedString("approvals.staleWarning", comment: "")
        static let detailTitle = NSLocalizedString("approvals.detailTitle", comment: "")
        static let detailChain = NSLocalizedString("approvals.detailChain", comment: "")
        static let detailAmount = NSLocalizedString("approvals.detailAmount", comment: "")
        static let detailRecipient = NSLocalizedString("approvals.detailRecipient", comment: "")
        static let detailInitiator = NSLocalizedString("approvals.detailInitiator", comment: "")
        static let detailStatus = NSLocalizedString("approvals.detailStatus", comment: "")
        static let detailCreated = NSLocalizedString("approvals.detailCreated", comment: "")
        static let detailResolved = NSLocalizedString("approvals.detailResolved", comment: "")
        static let detailSession = NSLocalizedString("approvals.detailSession", comment: "")
        static let detailResumeUnavailable = NSLocalizedString("approvals.detailResumeUnavailable", comment: "")
        static let actionResume = NSLocalizedString("approvals.actionResume", comment: "")
        static let resumeHint = NSLocalizedString("approvals.resumeHint", comment: "")
    }

    // MARK: - Onboarding

    enum Onboarding {
        static let welcomeTitle = NSLocalizedString("onboarding.welcomeTitle", comment: "")
        static let welcomeSubtitle = NSLocalizedString("onboarding.welcomeSubtitle", comment: "")
        static let getStarted = NSLocalizedString("onboarding.getStarted", comment: "")
        static let getStartedHint = NSLocalizedString("onboarding.getStartedHint", comment: "")
        static let createPin = NSLocalizedString("onboarding.createPin", comment: "")
        static let pinProtects = NSLocalizedString("onboarding.pinProtects", comment: "")
        static let enterPinPlaceholder = NSLocalizedString("onboarding.enterPinPlaceholder", comment: "")
        static let createPinHint = NSLocalizedString("onboarding.createPinHint", comment: "")
        static let nextHint = NSLocalizedString("onboarding.nextHint", comment: "")
        static let confirmPin = NSLocalizedString("onboarding.confirmPin", comment: "")
        static let enterSamePin = NSLocalizedString("onboarding.enterSamePin", comment: "")
        static let confirmPinHint = NSLocalizedString("onboarding.confirmPinHint", comment: "")
        static let pinsDontMatch = NSLocalizedString("onboarding.pinsDontMatch", comment: "")
        static let createWallet = NSLocalizedString("onboarding.createWallet", comment: "")
        static let createWalletHint = NSLocalizedString("onboarding.createWalletHint", comment: "")
    }

    // MARK: - Lock Screen

    enum LockScreen {
        static let title = NSLocalizedString("lockScreen.title", comment: "")
        static let subtitle = NSLocalizedString("lockScreen.subtitle", comment: "")
        static let pinHint = NSLocalizedString("lockScreen.pinHint", comment: "")
        static let unlock = NSLocalizedString("lockScreen.unlock", comment: "")
        static let unlockHint = NSLocalizedString("lockScreen.unlockHint", comment: "")
        static let useFaceID = NSLocalizedString("lockScreen.useFaceID", comment: "")
        static let unlockBiometricHint = NSLocalizedString("lockScreen.unlockBiometricHint", comment: "")
        static let dataWiped = NSLocalizedString("lockScreen.dataWiped", comment: "")
        static let biometricUnavailable = NSLocalizedString("lockScreen.biometricUnavailable", comment: "")

        static func tooManyAttempts(_ seconds: Int) -> String {
            String(format: NSLocalizedString("lockScreen.tooManyAttempts", comment: ""), seconds)
        }

        static func incorrectPin(_ remaining: Int) -> String {
            String(format: NSLocalizedString("lockScreen.incorrectPin", comment: ""), remaining)
        }
    }

    // MARK: - Wallet Home

    enum WalletHome {
        static let title = NSLocalizedString("walletHome.title", comment: "")
        static let noWalletsTitle = NSLocalizedString("walletHome.noWalletsTitle", comment: "")
        static let noWalletsSubtitle = NSLocalizedString("walletHome.noWalletsSubtitle", comment: "")
        static let createWallet = NSLocalizedString("walletHome.createWallet", comment: "")
        static let createFirstWallet = NSLocalizedString("walletHome.createFirstWallet", comment: "")
        static let createNewWallet = NSLocalizedString("walletHome.createNewWallet", comment: "")
        static let opensCreationFlow = NSLocalizedString("walletHome.opensCreationFlow", comment: "")
        static let startMPCHint = NSLocalizedString("walletHome.startMPCHint", comment: "")
        static let viewDetailsHint = NSLocalizedString("walletHome.viewDetailsHint", comment: "")
        static let editWalletList = NSLocalizedString("walletHome.editWalletList", comment: "")
        static let pendingBroadcasts = NSLocalizedString("walletHome.pendingBroadcasts", comment: "")
        static func pendingBroadcastsCount(_ n: Int) -> String {
            String(format: NSLocalizedString("walletHome.pendingBroadcastsCount", comment: ""), n)
        }
        static let loadingBalance = NSLocalizedString("walletHome.loadingBalance", comment: "")
        static func showMoreChains(_ n: Int) -> String {
            String(format: NSLocalizedString("walletHome.showMoreChains", comment: ""), n)
        }
        static let hideEmptyChains = NSLocalizedString("walletHome.hideEmptyChains", comment: "")
        static let sharedAddressHint = NSLocalizedString("walletHome.sharedAddressHint", comment: "")
        static func collapsedFundedOfTotal(_ funded: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("walletHome.collapsedFundedOfTotal", comment: ""), funded, total)
        }
        static func collapsedAllEmpty(_ total: Int) -> String {
            String(format: NSLocalizedString("walletHome.collapsedAllEmpty", comment: ""), total)
        }

        // dev.40 i18n batch
        static let restoreFromBackup = NSLocalizedString("wallet.restoreFromBackup", comment: "")
        static let speedUp = NSLocalizedString("wallet.speedUp", comment: "")
        static let deleteWallet = NSLocalizedString("wallet.deleteWallet", comment: "")
        static let renameTitle = NSLocalizedString("wallet.renameTitle", comment: "")
        static let walletNamePlaceholder = NSLocalizedString("wallet.walletNamePlaceholder", comment: "")
        static func hiddenCount(_ n: Int) -> String {
            String(format: NSLocalizedString("wallet.hiddenCount", comment: ""), n)
        }

        static func nodeUnreachable(_ chains: String) -> String {
            String(format: NSLocalizedString("walletHome.nodeUnreachable", comment: ""), chains)
        }

        static func nodesUnreachable(_ chains: String) -> String {
            String(format: NSLocalizedString("walletHome.nodesUnreachable", comment: ""), chains)
        }

        // Security health card
        static let securityTitleSafe = NSLocalizedString("walletHome.security.title.safe", comment: "")
        static let securityTitleAttention = NSLocalizedString("walletHome.security.title.attention", comment: "")
        static let securityTitleRisk = NSLocalizedString("walletHome.security.title.risk", comment: "")
        static let securityRotationRow = NSLocalizedString("walletHome.security.rotationRow", comment: "")
        static let securityRotationNever = NSLocalizedString("walletHome.security.rotationNever", comment: "")
        static func securityRotationAgo(_ days: Int) -> String {
            String(format: NSLocalizedString("walletHome.security.rotationAgo", comment: ""), days)
        }
        static let securityBackupRow = NSLocalizedString("walletHome.security.backupRow", comment: "")
        static let securityBackupOn = NSLocalizedString("walletHome.security.backupOn", comment: "")
        static let securityBackupOff = NSLocalizedString("walletHome.security.backupOff", comment: "")
        static let securityViewDetails = NSLocalizedString("walletHome.security.viewDetails", comment: "")

        static func networkWarning(_ chains: String) -> String {
            String(format: NSLocalizedString("walletHome.networkWarning", comment: ""), chains)
        }
    }

    // MARK: - Security Detail (P3)

    enum SecurityDetail {
        static let title = NSLocalizedString("securityDetail.title", comment: "")
        static let overallBlurb = NSLocalizedString("securityDetail.overallBlurb", comment: "")
        static let rotationTitle = NSLocalizedString("securityDetail.rotation.title", comment: "")
        static let rotationSubtitle = NSLocalizedString("securityDetail.rotation.subtitle", comment: "")
        static let rotationNone = NSLocalizedString("securityDetail.rotation.none", comment: "")
        static let backupTitle = NSLocalizedString("securityDetail.backup.title", comment: "")
        static let backupSubtitle = NSLocalizedString("securityDetail.backup.subtitle", comment: "")
        static let backupUnavailable = NSLocalizedString("securityDetail.backup.unavailable", comment: "")
        static let backupHint = NSLocalizedString("securityDetail.backup.hint", comment: "")
        static let backupEnable = NSLocalizedString("securityDetail.backup.enable", comment: "")
        static let backupEnabling = NSLocalizedString("securityDetail.backup.enabling", comment: "")
        static let backupEnableFailedTitle = NSLocalizedString("securityDetail.backup.enableFailedTitle", comment: "")
        static let backupEnableFailedGeneric = NSLocalizedString("securityDetail.backup.enableFailedGeneric", comment: "")
        static let backupRelockedTitle = NSLocalizedString("securityDetail.backup.relockedTitle", comment: "")
        static let backupRelockedMsg = NSLocalizedString("securityDetail.backup.relockedMsg", comment: "")
        static let backupPinFooter = NSLocalizedString("securityDetail.backup.pinFooter", comment: "")
        static let mpcTitle = NSLocalizedString("securityDetail.mpc.title", comment: "")
        static let mpcTip1 = NSLocalizedString("securityDetail.mpc.tip1", comment: "")
        static let mpcTip2 = NSLocalizedString("securityDetail.mpc.tip2", comment: "")
        static let mpcTip3 = NSLocalizedString("securityDetail.mpc.tip3", comment: "")
        static let shardGenericName = NSLocalizedString("securityDetail.shardGenericName", comment: "")
    }

    // MARK: - Pending Broadcast

    enum Pending {
        static let retry = NSLocalizedString("pending.retry", comment: "")
        static let discard = NSLocalizedString("pending.discard", comment: "")

        static func attempts(_ count: Int) -> String {
            String(format: NSLocalizedString("pending.attempts", comment: ""), count)
        }
    }

    // MARK: - Wallet Detail

    enum WalletDetail {
        static let actions = NSLocalizedString("walletDetail.actions", comment: "")
        static let sendTransaction = NSLocalizedString("walletDetail.sendTransaction", comment: "")
        static let openSigningHint = NSLocalizedString("walletDetail.openSigningHint", comment: "")
        static let receive = NSLocalizedString("walletDetail.receive", comment: "")
        static let showQRHint = NSLocalizedString("walletDetail.showQRHint", comment: "")
        static let tokens = NSLocalizedString("walletDetail.tokens", comment: "")
        static let loadingTokens = NSLocalizedString("walletDetail.loadingTokens", comment: "")
        static let noTokens = NSLocalizedString("walletDetail.noTokens", comment: "")
        static func noTokensDescription(_ standard: String) -> String {
            String(format: NSLocalizedString("walletDetail.noTokensDescription", comment: ""), standard)
        }
        static let recentTransactions = NSLocalizedString("walletDetail.recentTransactions", comment: "")
        static let viewAllHistory = NSLocalizedString("walletDetail.viewAllHistory", comment: "")
        static let transactions = NSLocalizedString("walletDetail.transactions", comment: "")
        static let transactionHistory = NSLocalizedString("walletDetail.transactionHistory", comment: "")
        static let details = NSLocalizedString("walletDetail.details", comment: "")
        static let chain = NSLocalizedString("walletDetail.chain", comment: "")
        static let threshold = NSLocalizedString("walletDetail.threshold", comment: "")
        static let created = NSLocalizedString("walletDetail.created", comment: "")
        static let walletAddress = NSLocalizedString("walletDetail.walletAddress", comment: "")
        static let copyAddress = NSLocalizedString("walletDetail.copyAddress", comment: "")
        static let addressCopied = NSLocalizedString("walletDetail.addressCopied", comment: "")
        static let copyWalletAddress = NSLocalizedString("walletDetail.copyWalletAddress", comment: "")
        static let copiesAddressHint = NSLocalizedString("walletDetail.copiesAddressHint", comment: "")

        static let yourShard = NSLocalizedString("walletDetail.yourShard", comment: "")

        static func shardNumber(_ index: Int) -> String {
            String(format: NSLocalizedString("walletDetail.shardNumber", comment: ""), index)
        }

        static func thresholdValue(_ t: Int, _ n: Int) -> String {
            String(format: NSLocalizedString("walletDetail.thresholdValue", comment: ""), t, n)
        }
    }

    // MARK: - Receive

    enum Receive {
        static let title = NSLocalizedString("receive.title", comment: "")
        static let qrError = NSLocalizedString("receive.qrError", comment: "")
        static let qrFailed = NSLocalizedString("receive.qrFailed", comment: "")
        static let copyAddress = NSLocalizedString("receive.copyAddress", comment: "")
        static let addressCopied = NSLocalizedString("receive.addressCopied", comment: "")
        static let copiesHint = NSLocalizedString("receive.copiesHint", comment: "")
        static let shareAddress = NSLocalizedString("receive.shareAddress", comment: "")
        static let shareHint = NSLocalizedString("receive.shareHint", comment: "")
        static let qrShareHint = NSLocalizedString("receive.qrShareHint", comment: "")

        static func receiveSymbol(_ symbol: String) -> String {
            String(format: NSLocalizedString("receive.receiveSymbol", comment: ""), symbol)
        }

        static func qrCodeAccessibility(_ symbol: String) -> String {
            String(format: NSLocalizedString("receive.qrCodeAccessibility", comment: ""), symbol)
        }

        static func copiedClears(_ seconds: Int) -> String {
            String(format: NSLocalizedString("receive.copiedClears", comment: ""), seconds)
        }
    }

    // MARK: - Transaction History

    enum TxHistory {
        static let title = NSLocalizedString("txHistory.title", comment: "")
        static let noTransactionsTitle = NSLocalizedString("txHistory.noTransactionsTitle", comment: "")
        static let noTransactionsSubtitle = NSLocalizedString("txHistory.noTransactionsSubtitle", comment: "")
        static let confirming = NSLocalizedString("txHistory.confirming", comment: "")

        static let filterAll = NSLocalizedString("txHistory.filterAll", comment: "")
        static let filterPending = NSLocalizedString("txHistory.filterPending", comment: "")
        static let filterConfirmed = NSLocalizedString("txHistory.filterConfirmed", comment: "")
        static let filterFailed = NSLocalizedString("txHistory.filterFailed", comment: "")
        static let statusPickerLabel = NSLocalizedString("txHistory.statusPickerLabel", comment: "")
        static let searchPrompt = NSLocalizedString("txHistory.searchPrompt", comment: "")
        static let refresh = NSLocalizedString("txHistory.refresh", comment: "")
        static let exportCSV = NSLocalizedString("txHistory.exportCSV", comment: "")
        static let syncUpToDate = NSLocalizedString("txHistory.syncUpToDate", comment: "")
        static let speedUpRBF = NSLocalizedString("txHistory.speedUpRBF", comment: "")
        static let speedUpRBFBody = NSLocalizedString("txHistory.speedUpRBFBody", comment: "")

        static func sendSymbol(_ symbol: String) -> String {
            String(format: NSLocalizedString("txHistory.sendSymbol", comment: ""), symbol)
        }
        static func syncedNew(_ n: Int) -> String {
            String(format: NSLocalizedString("txHistory.syncedNew", comment: ""), n)
        }
    }

    // MARK: - Transaction Detail

    enum TxDetail {
        static let title = NSLocalizedString("txDetail.title", comment: "")
        static let details = NSLocalizedString("txDetail.details", comment: "")
        static let chain = NSLocalizedString("txDetail.chain", comment: "")
        static let from = NSLocalizedString("txDetail.from", comment: "")
        static let to = NSLocalizedString("txDetail.to", comment: "")
        static let fee = NSLocalizedString("txDetail.fee", comment: "")
        static let signed = NSLocalizedString("txDetail.signed", comment: "")
        static let broadcast = NSLocalizedString("txDetail.broadcast", comment: "")
        static let transactionHash = NSLocalizedString("txDetail.transactionHash", comment: "")
        static let copyHash = NSLocalizedString("txDetail.copyHash", comment: "")
        static let copied = NSLocalizedString("txDetail.copied", comment: "")
        static let viewOnExplorer = NSLocalizedString("txDetail.viewOnExplorer", comment: "")
        static let statusSigned = NSLocalizedString("txDetail.statusSigned", comment: "")
        static let statusBroadcast = NSLocalizedString("txDetail.statusBroadcast", comment: "")
        static let statusConfirmed = NSLocalizedString("txDetail.statusConfirmed", comment: "")
        static let statusFailed = NSLocalizedString("txDetail.statusFailed", comment: "")
    }

    // MARK: - Create Shard

    enum CreateShard {
        static let title = NSLocalizedString("createShard.title", comment: "")
        static let walletName = NSLocalizedString("createShard.walletName", comment: "")
        static let walletNamePlaceholder = NSLocalizedString("createShard.walletNamePlaceholder", comment: "")
        static let walletNameAccessibility = NSLocalizedString("createShard.walletNameAccessibility", comment: "")
        static let walletNameHint = NSLocalizedString("createShard.walletNameHint", comment: "")
        static let blockchain = NSLocalizedString("createShard.blockchain", comment: "")
        static let chain = NSLocalizedString("createShard.chain", comment: "")
        static let threshold = NSLocalizedString("createShard.threshold", comment: "")
        static let communication = NSLocalizedString("createShard.communication", comment: "")
        static let nextFindPeers = NSLocalizedString("createShard.nextFindPeers", comment: "")
        static let findPeersHint = NSLocalizedString("createShard.findPeersHint", comment: "")

        static func totalParties(_ count: Int) -> String {
            String(format: NSLocalizedString("createShard.totalParties", comment: ""), count)
        }

        static func totalPartiesHint() -> String {
            NSLocalizedString("createShard.totalPartiesHint", comment: "")
        }

        static func signingThreshold(_ count: Int) -> String {
            String(format: NSLocalizedString("createShard.signingThreshold", comment: ""), count)
        }

        static func signingThresholdHint() -> String {
            NSLocalizedString("createShard.signingThresholdHint", comment: "")
        }

        static func requiresDevices(_ t: Int, _ n: Int) -> String {
            String(format: NSLocalizedString("createShard.requiresDevices", comment: ""), t, n)
        }

        // dev.44 — flow batch
        static let rolePicker = NSLocalizedString("createShard.rolePicker", comment: "")
        static let roleCreate = NSLocalizedString("createShard.roleCreate", comment: "")
        static let roleJoin = NSLocalizedString("createShard.roleJoin", comment: "")
        static let creatorFooter = NSLocalizedString("createShard.creatorFooter", comment: "")
        static let joinerFooter = NSLocalizedString("createShard.joinerFooter", comment: "")
        static let mpcTitle = NSLocalizedString("createShard.mpcTitle", comment: "")
        static let mpcExplainerA11y = NSLocalizedString("createShard.mpcExplainerA11y", comment: "")
        static let joinerValueProp = NSLocalizedString("createShard.joinerValueProp", comment: "")
        static let chainEvmBtc = NSLocalizedString("createShard.chainEvmBtc", comment: "")
        static let chainSolana = NSLocalizedString("createShard.chainSolana", comment: "")
        static let addrsEvmBtc = NSLocalizedString("createShard.addrsEvmBtc", comment: "")
        static let addrSolana = NSLocalizedString("createShard.addrSolana", comment: "")
        static let advancedSettings = NSLocalizedString("createShard.advancedSettings", comment: "")
        static let advancedDefaults = NSLocalizedString("createShard.advancedDefaults", comment: "")
        static let connectMethod = NSLocalizedString("createShard.connectMethod", comment: "")
        static let joinerSimpleHint = NSLocalizedString("createShard.joinerSimpleHint", comment: "")
        static let nextWaitCreator = NSLocalizedString("createShard.nextWaitCreator", comment: "")
        static let nofnAlertTitle = NSLocalizedString("createShard.nofnAlertTitle", comment: "")
        static let nofnContinue = NSLocalizedString("createShard.nofnContinue", comment: "")
        static let nofnRevert = NSLocalizedString("createShard.nofnRevert", comment: "")
        static let recommendedNof3 = NSLocalizedString("createShard.recommendedNof3", comment: "")
        static let noRedundancyBody = NSLocalizedString("createShard.noRedundancyBody", comment: "")
        static let relayServer = NSLocalizedString("createShard.relayServer", comment: "")
        static let relayServerHint = NSLocalizedString("createShard.relayServerHint", comment: "")
        static let roomCodeLabel = NSLocalizedString("createShard.roomCodeLabel", comment: "")
        static let roomCodePlaceholder = NSLocalizedString("createShard.roomCodePlaceholder", comment: "")
        static let regenRoomCodeA11y = NSLocalizedString("createShard.regenRoomCodeA11y", comment: "")
        static let scanRoomA11y = NSLocalizedString("createShard.scanRoomA11y", comment: "")
        static let copyRoomCodeA11y = NSLocalizedString("createShard.copyRoomCodeA11y", comment: "")
        static let copyRoomCode = NSLocalizedString("createShard.copyRoomCode", comment: "")
        static let showQR = NSLocalizedString("createShard.showQR", comment: "")
        static let scanToJoin = NSLocalizedString("createShard.scanToJoin", comment: "")
        static let scanHint = NSLocalizedString("createShard.scanHint", comment: "")
        static let roomCodeInvalid = NSLocalizedString("createShard.roomCodeInvalid", comment: "")
        static let scanRoomTitle = NSLocalizedString("createShard.scanRoomTitle", comment: "")
        static let roomCodeEphemeralHint = NSLocalizedString("createShard.roomCodeEphemeralHint", comment: "")
        static let roomCodeCopied = NSLocalizedString("createShard.roomCodeCopied", comment: "")
        static let pasteRoomCodeA11y = NSLocalizedString("createShard.pasteRoomCodeA11y", comment: "")
        static let roomCodeCreatorHint = NSLocalizedString("createShard.roomCodeCreatorHint", comment: "")
        static let shareRoom = NSLocalizedString("createShard.shareRoom", comment: "")
        static let shareRoomSubject = NSLocalizedString("createShard.shareRoomSubject", comment: "")
        static func shareRoomMessage(_ code: String) -> String {
            String(format: NSLocalizedString("createShard.shareRoomMessage", comment: ""), code)
        }
        static let shareRoomQR = NSLocalizedString("createShard.shareRoomQR", comment: "")

        // MPC explainer sheet
        static let explainerNoMnemonicTitle = NSLocalizedString("createShard.explainerNoMnemonicTitle", comment: "")
        static let explainerNoMnemonicBody = NSLocalizedString("createShard.explainerNoMnemonicBody", comment: "")
        static let explainerShardsTitle = NSLocalizedString("createShard.explainerShardsTitle", comment: "")
        static let explainerShardsBody = NSLocalizedString("createShard.explainerShardsBody", comment: "")
        static let explainerRecoverTitle = NSLocalizedString("createShard.explainerRecoverTitle", comment: "")
        static let explainerRecoverBody = NSLocalizedString("createShard.explainerRecoverBody", comment: "")
        static let explainerMultiChainTitle = NSLocalizedString("createShard.explainerMultiChainTitle", comment: "")
        static let explainerMultiChainBody = NSLocalizedString("createShard.explainerMultiChainBody", comment: "")
        static let explainerNavTitle = NSLocalizedString("createShard.explainerNavTitle", comment: "")
        static let explainerDone = NSLocalizedString("createShard.explainerDone", comment: "")

        // Stepper bar
        static let stepConfigure = NSLocalizedString("createShard.stepConfigure", comment: "")
        static let stepDiscover = NSLocalizedString("createShard.stepDiscover", comment: "")
        static let stepGenerate = NSLocalizedString("createShard.stepGenerate", comment: "")
        static let stepDone = NSLocalizedString("createShard.stepDone", comment: "")

        static func creatorValueProp(_ total: Int, _ threshold: Int) -> String {
            String(format: NSLocalizedString("createShard.creatorValueProp", comment: ""), total, threshold)
        }
        static func nofnAlertBody(_ threshold: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("createShard.nofnAlertBody", comment: ""), threshold, total)
        }
        static func noRedundancyTitle(_ threshold: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("createShard.noRedundancyTitle", comment: ""), threshold, total)
        }
    }

    // MARK: - Discovery

    enum Discovery {
        static let lookingForDevices = NSLocalizedString("discovery.lookingForDevices", comment: "")
        static let startKeyGeneration = NSLocalizedString("discovery.startKeyGeneration", comment: "")
        static let startKeyGenHint = NSLocalizedString("discovery.startKeyGenHint", comment: "")

        static func peersFound(_ found: Int, _ needed: Int) -> String {
            String(format: NSLocalizedString("discovery.peersFound", comment: ""), found, needed)
        }

        static func peersFoundAccessibility(_ found: Int, _ needed: Int) -> String {
            String(format: NSLocalizedString("discovery.peersFoundAccessibility", comment: ""), found, needed)
        }

        static func timeoutIn(_ seconds: Int) -> String {
            String(format: NSLocalizedString("discovery.timeoutIn", comment: ""), seconds)
        }

        // dev.44 — discovery UI strings
        static let secondsTimeout = NSLocalizedString("discovery.secondsTimeout", comment: "")
        static let waitingInitiator = NSLocalizedString("discovery.waitingInitiator", comment: "")
        static let initiatorLabel = NSLocalizedString("discovery.initiatorLabel", comment: "")
        static let joinerLabel = NSLocalizedString("discovery.joinerLabel", comment: "")
        static let joinerHint = NSLocalizedString("discovery.joinerHint", comment: "")
        static let joinerWaitStart = NSLocalizedString("discovery.joinerWaitStart", comment: "")

        static func initiatorId(_ id: String) -> String {
            String(format: NSLocalizedString("discovery.initiatorId", comment: ""), id)
        }
        static func joinerId(_ id: String) -> String {
            String(format: NSLocalizedString("discovery.joinerId", comment: ""), id)
        }
        static func connectedWaiting(_ count: Int) -> String {
            String(format: NSLocalizedString("discovery.connectedWaiting", comment: ""), count)
        }
    }

    // MARK: - DKG

    enum DKG {
        static let keyGenProgress = NSLocalizedString("dkg.keyGenProgress", comment: "")
        static let generatingKeyShards = NSLocalizedString("dkg.generatingKeyShards", comment: "")
        static let keepDevicesNearby = NSLocalizedString("dkg.keepDevicesNearby", comment: "")
        static let cancelCeremony = NSLocalizedString("dkg.cancelCeremony", comment: "")
        static let walletCreated = NSLocalizedString("dkg.walletCreated", comment: "")
        static let saveEncryptShard = NSLocalizedString("dkg.saveEncryptShard", comment: "")
        static let saveEncryptHint = NSLocalizedString("dkg.saveEncryptHint", comment: "")
        static let enterPinEncrypt = NSLocalizedString("dkg.enterPinEncrypt", comment: "")
        static let encryptSave = NSLocalizedString("dkg.encryptSave", comment: "")
        static let incorrectPin = NSLocalizedString("dkg.incorrectPin", comment: "")
        static let pinNeededEncrypt = NSLocalizedString("dkg.pinNeededEncrypt", comment: "")
        static let keyGenFailed = NSLocalizedString("dkg.keyGenFailed", comment: "")
        static let retryHint = NSLocalizedString("dkg.retryHint", comment: "")
        static let ceremonyCancel = NSLocalizedString("dkg.ceremonyCancel", comment: "")
        static let compromisedDevice = NSLocalizedString("dkg.compromisedDevice", comment: "")
        static let peerTimeout = NSLocalizedString("dkg.peerTimeout", comment: "")

        // Status messages
        static let searchingDevices = NSLocalizedString("dkg.searchingDevices", comment: "")
        static let initializingKeyGen = NSLocalizedString("dkg.initializingKeyGen", comment: "")
        static let exchangingCommitments = NSLocalizedString("dkg.exchangingCommitments", comment: "")
        static let verifyingShares = NSLocalizedString("dkg.verifyingShares", comment: "")
        static let finalizingKeyPackage = NSLocalizedString("dkg.finalizingKeyPackage", comment: "")
        static let computingPaillierKeys = NSLocalizedString("dkg.computingPaillierKeys", comment: "")
        static let generatingZKProofs = NSLocalizedString("dkg.generatingZKProofs", comment: "")
        static let verifyingProofs = NSLocalizedString("dkg.verifyingProofs", comment: "")
        static let computingAuxInfo = NSLocalizedString("dkg.computingAuxInfo", comment: "")
        static let finalizingKeyShares = NSLocalizedString("dkg.finalizingKeyShares", comment: "")
        static let derivingAddress = NSLocalizedString("dkg.derivingAddress", comment: "")
        static let processing = NSLocalizedString("dkg.processing", comment: "")

        static func roundOf(_ current: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("dkg.roundOf", comment: ""), current, total)
        }

        static func keyGenRound(_ current: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("dkg.keyGenRound", comment: ""), current, total)
        }

        static func yourShardIs(_ index: Int) -> String {
            String(format: NSLocalizedString("dkg.yourShardIs", comment: ""), index)
        }

        static func thresholdOf(_ t: Int, _ n: Int) -> String {
            String(format: NSLocalizedString("dkg.thresholdOf", comment: ""), t, n)
        }

        // dev.44 — progress + save fail alerts
        static let wrappingUp = NSLocalizedString("dkg.wrappingUp", comment: "")
        static let slowPathHint = NSLocalizedString("dkg.slowPathHint", comment: "")
        static let elapsedLabel = NSLocalizedString("dkg.elapsedLabel", comment: "")
        static let remainingLabel = NSLocalizedString("dkg.remainingLabel", comment: "")
        static let unbackedExitTitle = NSLocalizedString("dkg.unbackedExitTitle", comment: "")
        static let unbackedExitContinue = NSLocalizedString("dkg.unbackedExitContinue", comment: "")
        static let unbackedExitReturn = NSLocalizedString("dkg.unbackedExitReturn", comment: "")
        static let unbackedExitBody = NSLocalizedString("dkg.unbackedExitBody", comment: "")
        static let saveFailedTitle = NSLocalizedString("dkg.saveFailedTitle", comment: "")
        static let saveFailedOk = NSLocalizedString("dkg.saveFailedOk", comment: "")

        // VM errors
        static let errMissingKeygen = NSLocalizedString("dkg.errMissingKeygen", comment: "")
        static let errNoAddresses = NSLocalizedString("dkg.errNoAddresses", comment: "")
        static let errCannotUnlockVault = NSLocalizedString("dkg.errCannotUnlockVault", comment: "")
        static let errNotInParticipants = NSLocalizedString("dkg.errNotInParticipants", comment: "")

        static func errNotEnoughPeers(_ needed: Int, _ current: Int) -> String {
            String(format: NSLocalizedString("dkg.errNotEnoughPeers", comment: ""), needed, current)
        }
        static func errEncryptFailed(_ desc: String) -> String {
            String(format: NSLocalizedString("dkg.errEncryptFailed", comment: ""), desc)
        }
        static func errStoreFailed(_ desc: String) -> String {
            String(format: NSLocalizedString("dkg.errStoreFailed", comment: ""), desc)
        }
    }

    // MARK: - Backup Gate

    enum Backup {
        static let lastStep = NSLocalizedString("backup.lastStep", comment: "")
        static let whyBody = NSLocalizedString("backup.whyBody", comment: "")
        static let bullet1 = NSLocalizedString("backup.bullet1", comment: "")
        static let bullet2 = NSLocalizedString("backup.bullet2", comment: "")
        static let bullet3 = NSLocalizedString("backup.bullet3", comment: "")
        static let ackToggle = NSLocalizedString("backup.ackToggle", comment: "")
        static let doneButton = NSLocalizedString("backup.doneButton", comment: "")
        static let skipButton = NSLocalizedString("backup.skipButton", comment: "")
        static let navTitle = NSLocalizedString("backup.navTitle", comment: "")
    }

    // MARK: - Signing

    enum Signing {
        static let recipient = NSLocalizedString("signing.recipient", comment: "")
        static let addressPlaceholder = NSLocalizedString("signing.addressPlaceholder", comment: "")
        static let recipientAddress = NSLocalizedString("signing.recipientAddress", comment: "")
        static let recipientHint = NSLocalizedString("signing.recipientHint", comment: "")
        static let scanQR = NSLocalizedString("signing.scanQR", comment: "")
        static let scanQRHint = NSLocalizedString("signing.scanQRHint", comment: "")
        static let amount = NSLocalizedString("signing.amount", comment: "")
        static let amountHint = NSLocalizedString("signing.amountHint", comment: "")
        static let gas = NSLocalizedString("signing.gas", comment: "")
        static let estimating = NSLocalizedString("signing.estimating", comment: "")
        static let gasLimit = NSLocalizedString("signing.gasLimit", comment: "")
        static let estFee = NSLocalizedString("signing.estFee", comment: "")
        static let fee = NSLocalizedString("signing.fee", comment: "")
        static let unableToEstimate = NSLocalizedString("signing.unableToEstimate", comment: "")
        static let insufficientBalance = NSLocalizedString("signing.insufficientBalance", comment: "")
        static let availableBalance = NSLocalizedString("signing.availableBalance", comment: "")
        static let cannotEstimateFee = NSLocalizedString("signing.cannotEstimateFee", comment: "")
        static let estimateNetworkError = NSLocalizedString("signing.estimateNetworkError", comment: "")
        static let retryEstimate = NSLocalizedString("signing.retryEstimate", comment: "")
        static let nextInviteCoSigners = NSLocalizedString("signing.nextInviteCoSigners", comment: "")
        static let inviteHint = NSLocalizedString("signing.inviteHint", comment: "")
        static let inviteCoSigners = NSLocalizedString("signing.inviteCoSigners", comment: "")
        static let waitingForCoSigners = NSLocalizedString("signing.waitingForCoSigners", comment: "")
        static let walletFingerprintLabel = NSLocalizedString("signing.walletFingerprintLabel", comment: "")
        static let removePeer = NSLocalizedString("signing.removePeer", comment: "")
        static let removePeerConfirmTitle = NSLocalizedString("signing.removePeerConfirmTitle", comment: "")
        static func removePeerConfirmBody(_ name: String) -> String {
            String(format: NSLocalizedString("signing.removePeerConfirmBody", comment: ""), name)
        }
        static let roomCodeExpired = NSLocalizedString("signing.roomCodeExpired", comment: "")
        static let roomCodeRegenerate = NSLocalizedString("signing.roomCodeRegenerate", comment: "")
        static func roomCodeValidFor(_ countdown: String) -> String {
            String(format: NSLocalizedString("signing.roomCodeValidFor", comment: ""), countdown)
        }
        static let roomCodeCopied = NSLocalizedString("signing.roomCodeCopied", comment: "")
        static func lastSignedWith(_ name: String) -> String {
            String(format: NSLocalizedString("signing.lastSignedWith", comment: ""), name)
        }
        static let signAgainSameRecipient = NSLocalizedString("signing.signAgainSameRecipient", comment: "")
        static let forgetPeer = NSLocalizedString("signing.forgetPeer", comment: "")
        static let waitingTroubleshootTitle = NSLocalizedString("signing.waitingTroubleshootTitle", comment: "")
        static let waitingCheckCode = NSLocalizedString("signing.waitingCheckCode", comment: "")
        static let waitingCheckRelay = NSLocalizedString("signing.waitingCheckRelay", comment: "")
        static let waitingCheckLAN = NSLocalizedString("signing.waitingCheckLAN", comment: "")
        static let waitingEnableRelayHint = NSLocalizedString("signing.waitingEnableRelayHint", comment: "")
        static let joiningRoom = NSLocalizedString("signing.joiningRoom", comment: "")
        static let shareRoomCodeHint = NSLocalizedString("signing.shareRoomCodeHint", comment: "")
        static let transportTitle = NSLocalizedString("signing.transportTitle", comment: "")
        static let transportRelayTitle = NSLocalizedString("signing.transportRelayTitle", comment: "")
        static let transportRelaySubtitle = NSLocalizedString("signing.transportRelaySubtitle", comment: "")
        static let transportLANTitle = NSLocalizedString("signing.transportLANTitle", comment: "")
        static let transportLANSubtitle = NSLocalizedString("signing.transportLANSubtitle", comment: "")
        static let transportAtLeastOne = NSLocalizedString("signing.transportAtLeastOne", comment: "")
        static let transportModeAuto = NSLocalizedString("signing.transportModeAuto", comment: "")
        static let transportModeRelayOnly = NSLocalizedString("signing.transportModeRelayOnly", comment: "")
        static let transportModeLANOnly = NSLocalizedString("signing.transportModeLANOnly", comment: "")
        static let signTransaction = NSLocalizedString("signing.signTransaction", comment: "")
        static let signHint = NSLocalizedString("signing.signHint", comment: "")
        static let enterPinDecrypt = NSLocalizedString("signing.enterPinDecrypt", comment: "")
        static let unlockSign = NSLocalizedString("signing.unlockSign", comment: "")
        static let incorrectPin = NSLocalizedString("signing.incorrectPin", comment: "")
        static let pinNeededDecrypt = NSLocalizedString("signing.pinNeededDecrypt", comment: "")
        static let signingProgress = NSLocalizedString("signing.signingProgress", comment: "")
        static let signingTransaction = NSLocalizedString("signing.signingTransaction", comment: "")
        static let cancelSigning = NSLocalizedString("signing.cancelSigning", comment: "")
        static let transactionSigned = NSLocalizedString("signing.transactionSigned", comment: "")
        static let broadcasting = NSLocalizedString("signing.broadcasting", comment: "")
        static let broadcastToNetwork = NSLocalizedString("signing.broadcastToNetwork", comment: "")
        static let broadcastHint = NSLocalizedString("signing.broadcastHint", comment: "")
        static let saveForLater = NSLocalizedString("signing.saveForLater", comment: "")
        static let saveForLaterHint = NSLocalizedString("signing.saveForLaterHint", comment: "")
        static let signingFailed = NSLocalizedString("signing.signingFailed", comment: "")
        static let retryHint = NSLocalizedString("signing.retryHint", comment: "")
        static let cancelledByUser = NSLocalizedString("signing.cancelledByUser", comment: "")
        static let compromisedDevice = NSLocalizedString("signing.compromisedDevice", comment: "")

        // Status messages
        static let initializingProtocol = NSLocalizedString("signing.initializingProtocol", comment: "")
        static let waitingForInitiator = NSLocalizedString("signing.waitingForInitiator", comment: "")
        static let broadcastingNonces = NSLocalizedString("signing.broadcastingNonces", comment: "")
        static let exchangingNonces = NSLocalizedString("signing.exchangingNonces", comment: "")
        static let computingSignatureShares = NSLocalizedString("signing.computingSignatureShares", comment: "")
        static let computingPartialSigs = NSLocalizedString("signing.computingPartialSigs", comment: "")
        static let combiningSig = NSLocalizedString("signing.combiningSig", comment: "")
        static let verifyingSig = NSLocalizedString("signing.verifyingSig", comment: "")

        static func sendSymbol(_ symbol: String) -> String {
            String(format: NSLocalizedString("signing.sendSymbol", comment: ""), symbol)
        }

        static func needMoreSigners(_ count: Int) -> String {
            String(format: NSLocalizedString("signing.needMoreSigners", comment: ""), count)
        }

        static func signersReady(_ joined: Int, _ needed: Int) -> String {
            String(format: NSLocalizedString("signing.signersReady", comment: ""), joined, needed)
        }

        static let unlockToSignTitle = NSLocalizedString("signing.unlockToSignTitle", comment: "")
        static let unlockToSignSubtitle = NSLocalizedString("signing.unlockToSignSubtitle", comment: "")

        static func roundOf(_ current: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("signing.roundOf", comment: ""), current, total)
        }

        static func signingRound(_ current: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("signing.signingRound", comment: ""), current, total)
        }

        static func broadcastingTo(_ chain: String) -> String {
            String(format: NSLocalizedString("signing.broadcastingTo", comment: ""), chain)
        }

        // dev.43 signing-flow batch
        static let pickFromAddressBook = NSLocalizedString("sign.pickFromAddressBook", comment: "")
        static let asset = NSLocalizedString("sign.asset", comment: "")
        static let feePriority = NSLocalizedString("sign.feePriority", comment: "")
        static let customGasPlaceholder = NSLocalizedString("sign.customGasPlaceholder", comment: "")
        static let customFeeRateLabel = NSLocalizedString("sign.customFeeRateLabel", comment: "")
        static let customFeeRatePlaceholder = NSLocalizedString("sign.customFeeRatePlaceholder", comment: "")
        static let coSigners = NSLocalizedString("sign.coSigners", comment: "")
        static let selfLabel = NSLocalizedString("sign.selfLabel", comment: "")
        static let slowHint = NSLocalizedString("sign.slowHint", comment: "")
        static let waitingCoSigner = NSLocalizedString("sign.waitingCoSigner", comment: "")
        static let waiting = NSLocalizedString("sign.waiting", comment: "")
        static let bioReason = NSLocalizedString("sign.bioReason", comment: "")
        static let nativeTransfer = NSLocalizedString("sign.nativeTransfer", comment: "")
        static let warnZeroAmount = NSLocalizedString("sign.warnZeroAmount", comment: "")
        static let warnSelfTransfer = NSLocalizedString("sign.warnSelfTransfer", comment: "")
        static let preview = NSLocalizedString("sign.preview", comment: "")
        static let offlineDecoded = NSLocalizedString("sign.offlineDecoded", comment: "")
        static let rowOperation = NSLocalizedString("sign.rowOperation", comment: "")
        static let rowAsset = NSLocalizedString("sign.rowAsset", comment: "")
        static let rowAmount = NSLocalizedString("sign.rowAmount", comment: "")
        static let rowContract = NSLocalizedString("sign.rowContract", comment: "")
        static let rowNetworkFee = NSLocalizedString("sign.rowNetworkFee", comment: "")
        static let recipientSegments = NSLocalizedString("sign.recipientSegments", comment: "")
        static let addressCopied = NSLocalizedString("sign.addressCopied", comment: "")
        static let a11yCopyRecipient = NSLocalizedString("sign.a11yCopyRecipient", comment: "")
        static let a11yExplorer = NSLocalizedString("sign.a11yExplorer", comment: "")
        static let balanceChange = NSLocalizedString("sign.balanceChange", comment: "")

        static func ensResolving(_ name: String) -> String {
            String(format: NSLocalizedString("sign.ensResolving", comment: ""), name)
        }
        static func tokenTransferDescContract(_ amount: String, _ symbol: String) -> String {
            String(format: NSLocalizedString("sign.tokenTransferDescContract", comment: ""), amount, symbol)
        }
        static func tokenTransferDesc(_ amount: String, _ symbol: String) -> String {
            String(format: NSLocalizedString("sign.tokenTransferDesc", comment: ""), amount, symbol)
        }
        static func feeWarnPct(_ pct: Double) -> String {
            String(format: NSLocalizedString("sign.feeWarnPct", comment: ""), pct)
        }
    }

    // MARK: - QR Scanner

    enum Scanner {
        static let title = NSLocalizedString("scanner.title", comment: "")
        static let cameraNotAvailable = NSLocalizedString("scanner.cameraNotAvailable", comment: "")
        static let scanningArea = NSLocalizedString("scanner.scanningArea", comment: "")
        static let scanningHint = NSLocalizedString("scanner.scanningHint", comment: "")
    }

    // MARK: - Shards

    enum Shards {
        static let title = NSLocalizedString("shards.title", comment: "")
        static let noShards = NSLocalizedString("shards.noShards", comment: "")
        static let noShardsDescription = NSLocalizedString("shards.noShardsDescription", comment: "")
        static let importShard = NSLocalizedString("shards.importShard", comment: "")
        static let walletInfo = NSLocalizedString("shards.walletInfo", comment: "")
        static let wallet = NSLocalizedString("shards.wallet", comment: "")
        static let chain = NSLocalizedString("shards.chain", comment: "")
        static let address = NSLocalizedString("shards.address", comment: "")
        static let threshold = NSLocalizedString("shards.threshold", comment: "")
        static let actions = NSLocalizedString("shards.actions", comment: "")
        static let backupShard = NSLocalizedString("shards.backupShard", comment: "")
        static let deleteShard = NSLocalizedString("shards.deleteShard", comment: "")
        static let shardDetails = NSLocalizedString("shards.shardDetails", comment: "")
        static let deleteShardConfirm = NSLocalizedString("shards.deleteShardConfirm", comment: "")
        static let deleteShardMessage = NSLocalizedString("shards.deleteShardMessage", comment: "")

        static func shardNumber(_ index: Int) -> String {
            String(format: NSLocalizedString("shards.shardNumber", comment: ""), index)
        }

        static func thresholdValue(_ t: Int, _ n: Int) -> String {
            String(format: NSLocalizedString("shards.thresholdValue", comment: ""), t, n)
        }

        static func shardThreshold(_ t: Int, _ n: Int) -> String {
            String(format: NSLocalizedString("shards.shardThreshold", comment: ""), t, n)
        }

        // dev.45 — detail + delete UI
        static let restoreFromBackupA11y = NSLocalizedString("shards.restoreFromBackupA11y", comment: "")
        static let restoreFromBackupButton = NSLocalizedString("shards.restoreFromBackupButton", comment: "")
        static let derivedAddresses = NSLocalizedString("shards.derivedAddresses", comment: "")
        static let backupEntireAccount = NSLocalizedString("shards.backupEntireAccount", comment: "")
        static let deleteThisAccount = NSLocalizedString("shards.deleteThisAccount", comment: "")
        static let deleteIrreversible = NSLocalizedString("shards.deleteIrreversible", comment: "")
        static let deleteConfirmBoth = NSLocalizedString("shards.deleteConfirmBoth", comment: "")
        static let deleteAckBackup = NSLocalizedString("shards.deleteAckBackup", comment: "")
        static let deleteEnterPin = NSLocalizedString("shards.deleteEnterPin", comment: "")
        static let deletePermanent = NSLocalizedString("shards.deletePermanent", comment: "")
        static let deleteTitle = NSLocalizedString("shards.deleteTitle", comment: "")
        static let pinWrongRetry = NSLocalizedString("shards.pinWrongRetry", comment: "")

        static func myShardFraction(_ i: Int, _ n: Int) -> String {
            String(format: NSLocalizedString("shards.myShardFraction", comment: ""), i, n)
        }
        static func myShardHash(_ i: Int) -> String {
            String(format: NSLocalizedString("shards.myShardHash", comment: ""), i)
        }
        static func accountThresholdDesc(_ n: Int, _ t: Int) -> String {
            String(format: NSLocalizedString("shards.accountThresholdDesc", comment: ""), n, t)
        }
        static func deleteBody(_ name: String) -> String {
            String(format: NSLocalizedString("shards.deleteBody", comment: ""), name)
        }
        static func deleteShardLine(_ i: Int, _ n: Int) -> String {
            String(format: NSLocalizedString("shards.deleteShardLine", comment: ""), i, n)
        }
        static func deleteChainsLine(_ count: Int, _ chains: String) -> String {
            String(format: NSLocalizedString("shards.deleteChainsLine", comment: ""), count, chains)
        }
        static func deleteConsequence(_ threshold: Int) -> String {
            String(format: NSLocalizedString("shards.deleteConsequence", comment: ""), threshold)
        }
        static func deleteAckLoss(_ threshold: Int) -> String {
            String(format: NSLocalizedString("shards.deleteAckLoss", comment: ""), threshold)
        }
    }

    // MARK: - Shard Backup

    enum ShardBackup {
        static let title = NSLocalizedString("shardBackup.title", comment: "")
        static let description = NSLocalizedString("shardBackup.description", comment: "")
        static let devicePin = NSLocalizedString("shardBackup.devicePin", comment: "")
        static let enterPin = NSLocalizedString("shardBackup.enterPin", comment: "")
        static let exportEncrypted = NSLocalizedString("shardBackup.exportEncrypted", comment: "")
        static let ready = NSLocalizedString("shardBackup.ready", comment: "")
        static let exportOptions = NSLocalizedString("shardBackup.exportOptions", comment: "")
        static let saveToFiles = NSLocalizedString("shardBackup.saveToFiles", comment: "")
        static let copyToClipboard = NSLocalizedString("shardBackup.copyToClipboard", comment: "")
        static let qrCode = NSLocalizedString("shardBackup.qrCode", comment: "")
        static let shardBackupQR = NSLocalizedString("shardBackup.shardBackupQR", comment: "")
        static let unableToGenerateQR = NSLocalizedString("shardBackup.unableToGenerateQR", comment: "")

        static func copiedAutoClears(_ seconds: Int) -> String {
            String(format: NSLocalizedString("shardBackup.copiedAutoClears", comment: ""), seconds)
        }

        // dev.45 — backup sheet UI
        static let sheetNavTitle = NSLocalizedString("shardBackup.sheetNavTitle", comment: "")
        static let rkWillEncrypt = NSLocalizedString("shardBackup.rkWillEncrypt", comment: "")
        static let rkWillEncryptBody = NSLocalizedString("shardBackup.rkWillEncryptBody", comment: "")
        static let pinHeaderUnlockShard = NSLocalizedString("shardBackup.pinHeaderUnlockShard", comment: "")
        static let pinHeaderBackupPassword = NSLocalizedString("shardBackup.pinHeaderBackupPassword", comment: "")
        static let pinFooterRkReady = NSLocalizedString("shardBackup.pinFooterRkReady", comment: "")
        static let pinFooterExportEncrypts = NSLocalizedString("shardBackup.pinFooterExportEncrypts", comment: "")

        static func exportIntro(_ name: String) -> String {
            String(format: NSLocalizedString("shardBackup.exportIntro", comment: ""), name)
        }
        static func exportIncludesChains(_ count: Int) -> String {
            String(format: NSLocalizedString("shardBackup.exportIncludesChains", comment: ""), count)
        }
    }

    // MARK: - Shard Import

    enum ShardImport {
        static let title = NSLocalizedString("shardImport.title", comment: "")
        static let description = NSLocalizedString("shardImport.description", comment: "")
        static let importSource = NSLocalizedString("shardImport.importSource", comment: "")
        static let chooseFile = NSLocalizedString("shardImport.chooseFile", comment: "")
        static let pasteFromClipboard = NSLocalizedString("shardImport.pasteFromClipboard", comment: "")
        static let scanQRCode = NSLocalizedString("shardImport.scanQRCode", comment: "")
        static let backupInfo = NSLocalizedString("shardImport.backupInfo", comment: "")
        static let partyIndex = NSLocalizedString("shardImport.partyIndex", comment: "")
        static let backupVersion = NSLocalizedString("shardImport.backupVersion", comment: "")
        static let enterDevicePin = NSLocalizedString("shardImport.enterDevicePin", comment: "")
        static let reEncryptNote = NSLocalizedString("shardImport.reEncryptNote", comment: "")
        static let importShard = NSLocalizedString("shardImport.import", comment: "")
        static let chooseDifferent = NSLocalizedString("shardImport.chooseDifferent", comment: "")
        static let shardImported = NSLocalizedString("shardImport.shardImported", comment: "")
        static let unableToAccessFile = NSLocalizedString("shardImport.unableToAccessFile", comment: "")
        static let noClipboardData = NSLocalizedString("shardImport.noClipboardData", comment: "")
        static let invalidQRData = NSLocalizedString("shardImport.invalidQRData", comment: "")

        static func partyIndexValue(_ index: Int) -> String {
            String(format: NSLocalizedString("shardImport.partyIndexValue", comment: ""), index)
        }

        static func backupVersionValue(_ version: Int) -> String {
            String(format: NSLocalizedString("shardImport.backupVersionValue", comment: ""), version)
        }

        static func addedToDevice(_ name: String) -> String {
            String(format: NSLocalizedString("shardImport.addedToDevice", comment: ""), name)
        }

        // dev.45 — account import UI
        static let accountLabel = NSLocalizedString("shardImport.accountLabel", comment: "")
        static let chainLabel = NSLocalizedString("shardImport.chainLabel", comment: "")
        static let derivedWalletsLabel = NSLocalizedString("shardImport.derivedWalletsLabel", comment: "")
        static let encryptionMethod = NSLocalizedString("shardImport.encryptionMethod", comment: "")
        static let encryptionICloud = NSLocalizedString("shardImport.encryptionICloud", comment: "")
        static let encryptionPin = NSLocalizedString("shardImport.encryptionPin", comment: "")
        static let legacyFormatValue = NSLocalizedString("shardImport.legacyFormatValue", comment: "")
        static let rkInfoBanner = NSLocalizedString("shardImport.rkInfoBanner", comment: "")
        static let pinStillNeededForLocal = NSLocalizedString("shardImport.pinStillNeededForLocal", comment: "")
        static let pinEncryptsBackup = NSLocalizedString("shardImport.pinEncryptsBackup", comment: "")
        static let restoreAccountButton = NSLocalizedString("shardImport.restoreAccountButton", comment: "")
        static let failedToParseBackup = NSLocalizedString("shardImport.failedToParseBackup", comment: "")

        static func chainsCount(_ count: Int) -> String {
            String(format: NSLocalizedString("shardImport.chainsCount", comment: ""), count)
        }
        static func restoredAccount(_ name: String, _ count: Int) -> String {
            String(format: NSLocalizedString("shardImport.restoredAccount", comment: ""), name, count)
        }
        static func readFailed(_ desc: String) -> String {
            String(format: NSLocalizedString("shardImport.readFailed", comment: ""), desc)
        }
    }

    // MARK: - Settings

    enum Settings {
        static let title = NSLocalizedString("settings.title", comment: "")
        static let security = NSLocalizedString("settings.security", comment: "")
        static let faceIDTouchID = NSLocalizedString("settings.faceIDTouchID", comment: "")
        static let biometricHint = NSLocalizedString("settings.biometricHint", comment: "")
        static let changePin = NSLocalizedString("settings.changePin", comment: "")
        static let changePinHint = NSLocalizedString("settings.changePinHint", comment: "")
        static let autoLock = NSLocalizedString("settings.autoLock", comment: "")
        static let immediately = NSLocalizedString("settings.immediately", comment: "")
        static let oneMinute = NSLocalizedString("settings.oneMinute", comment: "")
        static let fiveMinutes = NSLocalizedString("settings.fiveMinutes", comment: "")
        static let fifteenMinutes = NSLocalizedString("settings.fifteenMinutes", comment: "")
        static let oneHour = NSLocalizedString("settings.oneHour", comment: "")
        static let never = NSLocalizedString("settings.never", comment: "")
        static let blockchainNodes = NSLocalizedString("settings.blockchainNodes", comment: "")
        static let rpcEndpoints = NSLocalizedString("settings.rpcEndpoints", comment: "")
        static let rpcEndpointsHint = NSLocalizedString("settings.rpcEndpointsHint", comment: "")
        static let network = NSLocalizedString("settings.network", comment: "")
        static let relayServer = NSLocalizedString("settings.relayServer", comment: "")
        static let webSocketURL = NSLocalizedString("settings.webSocketURL", comment: "")
        static let relayServerURL = NSLocalizedString("settings.relayServerURL", comment: "")
        static let relayURLHint = NSLocalizedString("settings.relayURLHint", comment: "")
        static let communication = NSLocalizedString("settings.communication", comment: "")

        // dev.40 i18n batch
        static let sectionContacts = NSLocalizedString("settings.section.contacts", comment: "")
        static let sectionTokens = NSLocalizedString("settings.section.tokens", comment: "")
        static let sectionDiagnostics = NSLocalizedString("settings.section.diagnostics", comment: "")
        static let sectionLanguage = NSLocalizedString("settings.section.language", comment: "")
        static let sectionDeviceMgmt = NSLocalizedString("settings.section.deviceMgmt", comment: "")
        static let sectionAdvanced = NSLocalizedString("settings.section.advanced", comment: "")
        static let addressBook = NSLocalizedString("settings.addressBook", comment: "")
        static let customTokens = NSLocalizedString("settings.customTokens", comment: "")
        static let shardHealth = NSLocalizedString("settings.shardHealth", comment: "")
        static let biometricSign = NSLocalizedString("settings.biometricSign", comment: "")
        static let biometricSignHint = NSLocalizedString("settings.biometricSignHint", comment: "")
        static let officialRelay = NSLocalizedString("settings.officialRelay", comment: "")
        static let customRelay = NSLocalizedString("settings.customRelay", comment: "")
        static let replaceDevice = NSLocalizedString("settings.replaceDevice", comment: "")
        static let replaceDeviceSubtitle = NSLocalizedString("settings.replaceDeviceSubtitle", comment: "")
        static let hardwareWallet = NSLocalizedString("settings.hardwareWallet", comment: "")
        static let comingSoon = NSLocalizedString("settings.comingSoon", comment: "")
        static let language = NSLocalizedString("settings.language", comment: "")
        static let languageFollowSystem = NSLocalizedString("settings.languageFollowSystem", comment: "")
        static let languageRestartFooter = NSLocalizedString("settings.languageRestartFooter", comment: "")
        static let languageRestartTitle = NSLocalizedString("settings.languageRestartTitle", comment: "")
        static let languageRestartMessage = NSLocalizedString("settings.languageRestartMessage", comment: "")

        static let transportPreferences = NSLocalizedString("settings.transportPreferences", comment: "")
        static let transportHint = NSLocalizedString("settings.transportHint", comment: "")
        static let about = NSLocalizedString("settings.about", comment: "")
        static let version = NSLocalizedString("settings.version", comment: "")
        static let coreLibrary = NSLocalizedString("settings.coreLibrary", comment: "")
        static let mpcProtocols = NSLocalizedString("settings.mpcProtocols", comment: "")
        static let e2eEncryption = NSLocalizedString("settings.e2eEncryption", comment: "")
        static let priceDataSources = NSLocalizedString("settings.priceDataSources", comment: "")
        static let secureEnclave = NSLocalizedString("settings.secureEnclave", comment: "")
        static let hardwareProtected = NSLocalizedString("settings.hardwareProtected", comment: "")
        static let softwareOnly = NSLocalizedString("settings.softwareOnly", comment: "")
        static let openSourceLicenses = NSLocalizedString("settings.openSourceLicenses", comment: "")
        static let licensesHint = NSLocalizedString("settings.licensesHint", comment: "")
        static let dangerZone = NSLocalizedString("settings.dangerZone", comment: "")
        static let wipeAllData = NSLocalizedString("settings.wipeAllData", comment: "")
        static let wipeAllDataSubtitle = NSLocalizedString("settings.wipeAllDataSubtitle", comment: "")
        static let wipeHint = NSLocalizedString("settings.wipeHint", comment: "")
        static let wipeConfirmTitle = NSLocalizedString("settings.wipeConfirmTitle", comment: "")
        static let wipeEverything = NSLocalizedString("settings.wipeEverything", comment: "")
        static let wipeMessage = NSLocalizedString("settings.wipeMessage", comment: "")
        static let wipePinTitle = NSLocalizedString("settings.wipePinTitle", comment: "")
        static let wipePinSubtitle = NSLocalizedString("settings.wipePinSubtitle", comment: "")
        static let wipePinWrong = NSLocalizedString("settings.wipePinWrong", comment: "")
        static let biometricDisableTitle = NSLocalizedString("settings.biometricDisableTitle", comment: "")
        static let biometricDisableSubtitle = NSLocalizedString("settings.biometricDisableSubtitle", comment: "")
        static let biometricDisablePinWrong = NSLocalizedString("settings.biometricDisablePinWrong", comment: "")
        static let connected = NSLocalizedString("settings.connected", comment: "")
        static let disconnected = NSLocalizedString("settings.disconnected", comment: "")
        static let relayStatusConnected = NSLocalizedString("settings.relayStatusConnected", comment: "")
        static let relayStatusDisconnected = NSLocalizedString("settings.relayStatusDisconnected", comment: "")
    }

    // MARK: - Transport

    enum Transport {
        static let title = NSLocalizedString("transport.title", comment: "")
        static let faceToFaceChannels = NSLocalizedString("transport.faceToFaceChannels", comment: "")
        static let ble = NSLocalizedString("transport.ble", comment: "")
        static let bleHint = NSLocalizedString("transport.bleHint", comment: "")
        static let wifiDirect = NSLocalizedString("transport.wifiDirect", comment: "")
        static let wifiDirectHint = NSLocalizedString("transport.wifiDirectHint", comment: "")
        static let wifiLAN = NSLocalizedString("transport.wifiLAN", comment: "")
        static let wifiLANHint = NSLocalizedString("transport.wifiLANHint", comment: "")
        static let info = NSLocalizedString("transport.info", comment: "")
    }

    // MARK: - Change PIN

    enum ChangePin {
        static let title = NSLocalizedString("changePin.title", comment: "")
        static let currentPin = NSLocalizedString("changePin.currentPin", comment: "")
        static let newPin = NSLocalizedString("changePin.newPin", comment: "")
        static let confirmNewPin = NSLocalizedString("changePin.confirmNewPin", comment: "")
        static let submit = NSLocalizedString("changePin.submit", comment: "")
        static let submitHint = NSLocalizedString("changePin.submitHint", comment: "")
        static let incorrectCurrent = NSLocalizedString("changePin.incorrectCurrent", comment: "")
        static let dontMatch = NSLocalizedString("changePin.dontMatch", comment: "")
        static let saveFailed = NSLocalizedString("changePin.saveFailed", comment: "")
    }

    // MARK: - Node Settings

    enum NodeSettings {
        static let title = NSLocalizedString("nodeSettings.title", comment: "")
        static let quickPresets = NSLocalizedString("nodeSettings.quickPresets", comment: "")
        static let ethereumEVM = NSLocalizedString("nodeSettings.ethereumEVM", comment: "")
        static let rpcURL = NSLocalizedString("nodeSettings.rpcURL", comment: "")
        static let networkPicker = NSLocalizedString("nodeSettings.networkPicker", comment: "")
        static let bitcoin = NSLocalizedString("nodeSettings.bitcoin", comment: "")
        static let restAPIURL = NSLocalizedString("nodeSettings.restAPIURL", comment: "")
        static let testnet = NSLocalizedString("nodeSettings.testnet", comment: "")
        static let testnetHint = NSLocalizedString("nodeSettings.testnetHint", comment: "")
        static let solana = NSLocalizedString("nodeSettings.solana", comment: "")
        static let devnet = NSLocalizedString("nodeSettings.devnet", comment: "")
        static let devnetHint = NSLocalizedString("nodeSettings.devnetHint", comment: "")
        static let resetToDefaults = NSLocalizedString("nodeSettings.resetToDefaults", comment: "")
        static let resetHint = NSLocalizedString("nodeSettings.resetHint", comment: "")
        static let resetConfirmTitle = NSLocalizedString("nodeSettings.resetConfirmTitle", comment: "")
        static let reset = NSLocalizedString("nodeSettings.reset", comment: "")
        static let resetMessage = NSLocalizedString("nodeSettings.resetMessage", comment: "")

        static func switchTo(_ name: String) -> String {
            String(format: NSLocalizedString("nodeSettings.switchTo", comment: ""), name)
        }

        static let litecoinSection = NSLocalizedString("nodeSettings.litecoinSection", comment: "")
        static let tronSection = NSLocalizedString("nodeSettings.tronSection", comment: "")
        static let heliusKeyLabel = NSLocalizedString("nodeSettings.heliusKeyLabel", comment: "")
        static let pasteKeyPlaceholder = NSLocalizedString("nodeSettings.pasteKeyPlaceholder", comment: "")
        static let useHelius = NSLocalizedString("nodeSettings.useHelius", comment: "")
        static let etherscanKeyLabel = NSLocalizedString("nodeSettings.etherscanKeyLabel", comment: "")
        static let etherscanKeyHelp = NSLocalizedString("nodeSettings.etherscanKeyHelp", comment: "")
        static let readOnlyTag = NSLocalizedString("nodeSettings.readOnlyTag", comment: "")
        static let readOnlyNote = NSLocalizedString("nodeSettings.readOnlyNote", comment: "")
        static let importExportSection = NSLocalizedString("nodeSettings.importExportSection", comment: "")
        static let exportConfig = NSLocalizedString("nodeSettings.exportConfig", comment: "")
        static let importConfig = NSLocalizedString("nodeSettings.importConfig", comment: "")
        static let importPasteTitle = NSLocalizedString("nodeSettings.importPasteTitle", comment: "")
        static let importPastePlaceholder = NSLocalizedString("nodeSettings.importPastePlaceholder", comment: "")
        static let importPreviewTitle = NSLocalizedString("nodeSettings.importPreviewTitle", comment: "")
        static let importApply = NSLocalizedString("nodeSettings.importApply", comment: "")
        static let importParseFailed = NSLocalizedString("nodeSettings.importParseFailed", comment: "")
        static let importNoChanges = NSLocalizedString("nodeSettings.importNoChanges", comment: "")
        static let exportNote = NSLocalizedString("nodeSettings.exportNote", comment: "")
        static let wssURLLabel = NSLocalizedString("nodeSettings.wssURLLabel", comment: "")
        static let wssHint = NSLocalizedString("nodeSettings.wssHint", comment: "")
        static let wssTest = NSLocalizedString("nodeSettings.wssTest", comment: "")
        static let wssTesting = NSLocalizedString("nodeSettings.wssTesting", comment: "")
        static func wssOK(_ ms: Int) -> String {
            String(format: NSLocalizedString("nodeSettings.wssOK", comment: ""), ms)
        }

        static let paidProviderPicker = NSLocalizedString("nodeSettings.paidProviderPicker", comment: "")

        static let presetConfirmTitle = NSLocalizedString("nodeSettings.presetConfirmTitle", comment: "")
        static let presetApply = NSLocalizedString("nodeSettings.presetApply", comment: "")

        static func applyProviderFor(_ provider: String, _ chain: String) -> String {
            String(format: NSLocalizedString("nodeSettings.applyProviderFor", comment: ""), provider, chain)
        }

        static func providerActiveFor(_ provider: String, _ chain: String) -> String {
            String(format: NSLocalizedString("nodeSettings.providerActiveFor", comment: ""), provider, chain)
        }

        static let advancedFields = NSLocalizedString("nodeSettings.advancedFields", comment: "")
        static let apiKeysSection = NSLocalizedString("nodeSettings.apiKeysSection", comment: "")
        static let apiKeysHint = NSLocalizedString("nodeSettings.apiKeysHint", comment: "")

        static func providerUnsupportedOnChain(_ provider: String, _ chain: String) -> String {
            String(format: NSLocalizedString("nodeSettings.providerUnsupportedOnChain", comment: ""), provider, chain)
        }

        // MARK: NodeProviderSection
        static let providerSection = NSLocalizedString("nodeSettings.providerSection", comment: "")
        static let providerPicker = NSLocalizedString("nodeSettings.providerPicker", comment: "")
        static let providerPublicDefaults = NSLocalizedString("nodeSettings.providerPublicDefaults", comment: "")
        static func providerKeyLabel(_ name: String) -> String {
            String(format: NSLocalizedString("nodeSettings.providerKeyLabel", comment: ""), name)
        }
        static let providerPublicCaption = NSLocalizedString("nodeSettings.providerPublicCaption", comment: "")

        // MARK: ProviderCoverageSummary
        static let chainListSeparator = NSLocalizedString("nodeSettings.chainListSeparator", comment: "")
        static let coverageNoKey = NSLocalizedString("nodeSettings.coverageNoKey", comment: "")
        static func coverageNoKeyWithOverrides(_ ownCount: Int, _ publicCount: Int) -> String {
            String(format: NSLocalizedString("nodeSettings.coverageNoKeyWithOverrides", comment: ""),
                   ownCount, publicCount)
        }
        static func coverageAllCovered(_ providerName: String, _ chainCount: Int) -> String {
            String(format: NSLocalizedString("nodeSettings.coverageAllCovered", comment: ""),
                   providerName, chainCount)
        }
        static func coverageAllWithOverrides(_ providerName: String, _ coveredCount: Int, _ ownCount: Int) -> String {
            String(format: NSLocalizedString("nodeSettings.coverageAllWithOverrides", comment: ""),
                   providerName, coveredCount, ownCount)
        }
        static func coveragePartial(_ providerName: String, _ coveredCount: Int, _ totalCount: Int, _ names: String) -> String {
            String(format: NSLocalizedString("nodeSettings.coveragePartial", comment: ""),
                   providerName, coveredCount, totalCount, names)
        }
        static func coveragePartialWithOverrides(_ providerName: String, _ coveredCount: Int, _ totalCount: Int, _ names: String, _ ownCount: Int) -> String {
            String(format: NSLocalizedString("nodeSettings.coveragePartialWithOverrides", comment: ""),
                   providerName, coveredCount, totalCount, names, ownCount)
        }
    }

    // MARK: - Node Status

    enum NodeStatus {
        static let notChecked = NSLocalizedString("nodeStatus.notChecked", comment: "")
        static let connected = NSLocalizedString("nodeStatus.connected", comment: "")
        static let checking = NSLocalizedString("nodeStatus.checking", comment: "")
        static let checkingAll = NSLocalizedString("nodeStatus.checkingAll", comment: "")
        static let testAll = NSLocalizedString("nodeStatus.testAll", comment: "")
        static let switchEndpoint = NSLocalizedString("nodeStatus.switchEndpoint", comment: "")
        static let currentEndpoint = NSLocalizedString("nodeStatus.currentEndpoint", comment: "")
        static let errNetwork = NSLocalizedString("nodeStatus.errNetwork", comment: "")
        static let errUnreachable = NSLocalizedString("nodeStatus.errUnreachable", comment: "")
        static let errTimeout = NSLocalizedString("nodeStatus.errTimeout", comment: "")
        static let justNow = NSLocalizedString("nodeStatus.justNow", comment: "")
        static let keyStoredSecurely = NSLocalizedString("nodeStatus.keyStoredSecurely", comment: "")
        static let bakedKeyWarning = NSLocalizedString("nodeStatus.bakedKeyWarning", comment: "")
        static let publicPrivacyNote = NSLocalizedString("nodeStatus.publicPrivacyNote", comment: "")
        static let cooldownBadge = NSLocalizedString("nodeStatus.cooldownBadge", comment: "")
        static let cooldownExplain = NSLocalizedString("nodeStatus.cooldownExplain", comment: "")
        static let cooldownSectionTitle = NSLocalizedString("nodeStatus.cooldownSectionTitle", comment: "")
        static let cooldownSectionFooter = NSLocalizedString("nodeStatus.cooldownSectionFooter", comment: "")
        static let cooldownRetry = NSLocalizedString("nodeStatus.cooldownRetry", comment: "")
        static func cooldownRemaining(_ rel: String) -> String {
            String(format: NSLocalizedString("nodeStatus.cooldownRemaining", comment: ""), rel)
        }
        static let networkMismatchExpectedMainnet = NSLocalizedString("nodeStatus.networkMismatchExpectedMainnet", comment: "")
        static let networkMismatchExpectedTestnet = NSLocalizedString("nodeStatus.networkMismatchExpectedTestnet", comment: "")
        static let resetThisChain = NSLocalizedString("nodeStatus.resetThisChain", comment: "")
        static let copyURL = NSLocalizedString("nodeStatus.copyURL", comment: "")

        static func chainMismatch(_ expected: String, _ actual: String) -> String {
            String(format: NSLocalizedString("nodeStatus.chainMismatch", comment: ""), expected, actual)
        }

        static func blockLagWarning(_ blocks: Int) -> String {
            String(format: NSLocalizedString("nodeStatus.blockLagWarning", comment: ""), blocks)
        }

        static let latencyTrend = NSLocalizedString("nodeStatus.latencyTrend", comment: "")

        static func healthySummary(_ ok: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("nodeStatus.healthySummary", comment: ""), ok, total)
        }

        static func latencyMs(_ ms: Int) -> String {
            String(format: NSLocalizedString("nodeStatus.latencyMs", comment: ""), ms)
        }

        static func blockHeight(_ h: UInt64) -> String {
            String(format: NSLocalizedString("nodeStatus.blockHeight", comment: ""), String(h))
        }

        static func lastOkPrefix(_ relative: String) -> String {
            String(format: NSLocalizedString("nodeStatus.lastOkPrefix", comment: ""), relative)
        }

        static func secondsAgo(_ s: Int) -> String {
            String(format: NSLocalizedString("nodeStatus.secondsAgo", comment: ""), s)
        }

        static func minutesAgo(_ m: Int) -> String {
            String(format: NSLocalizedString("nodeStatus.minutesAgo", comment: ""), m)
        }

        static func hoursAgo(_ h: Int) -> String {
            String(format: NSLocalizedString("nodeStatus.hoursAgo", comment: ""), h)
        }

        static func daysAgo(_ d: Int) -> String {
            String(format: NSLocalizedString("nodeStatus.daysAgo", comment: ""), d)
        }
    }

    // MARK: - Licenses

    enum Licenses {
        static let title = NSLocalizedString("licenses.title", comment: "")
        static let coreDependencies = NSLocalizedString("licenses.coreDependencies", comment: "")
    }

    // MARK: - Address Book (dev.46)

    enum AddressBook {
        static let empty = NSLocalizedString("addressBook.empty", comment: "")
        static let emptyHint = NSLocalizedString("addressBook.emptyHint", comment: "")
        static let title = NSLocalizedString("addressBook.title", comment: "")
        static let newContact = NSLocalizedString("addressBook.newContact", comment: "")
        static let export = NSLocalizedString("addressBook.export", comment: "")
        static let importLabel = NSLocalizedString("addressBook.import", comment: "")
        static let allExisted = NSLocalizedString("addressBook.allExisted", comment: "")
        static let importResultTitle = NSLocalizedString("addressBook.importResultTitle", comment: "")
        static let contactSection = NSLocalizedString("addressBook.contactSection", comment: "")
        static let labelPlaceholder = NSLocalizedString("addressBook.labelPlaceholder", comment: "")
        static let chainPickerLabel = NSLocalizedString("addressBook.chainPickerLabel", comment: "")
        static let addressPlaceholder = NSLocalizedString("addressBook.addressPlaceholder", comment: "")
        static let notePlaceholder = NSLocalizedString("addressBook.notePlaceholder", comment: "")
        static let navNew = NSLocalizedString("addressBook.navNew", comment: "")
        static let navEdit = NSLocalizedString("addressBook.navEdit", comment: "")
        static let saveButton = NSLocalizedString("addressBook.saveButton", comment: "")
        static let emptyOnChain = NSLocalizedString("addressBook.emptyOnChain", comment: "")
        static let pickContactTitle = NSLocalizedString("addressBook.pickContactTitle", comment: "")

        static func importedCount(_ n: Int) -> String {
            String(format: NSLocalizedString("addressBook.importedCount", comment: ""), n)
        }
        static func importFailed(_ desc: String) -> String {
            String(format: NSLocalizedString("addressBook.importFailed", comment: ""), desc)
        }
    }

    // MARK: - Custom Tokens (dev.46)

    enum CustomTokens {
        static let emptyTitle = NSLocalizedString("customTokens.emptyTitle", comment: "")
        static let emptyHint = NSLocalizedString("customTokens.emptyHint", comment: "")
        static let deleteLabel = NSLocalizedString("customTokens.deleteLabel", comment: "")
        static let navTitle = NSLocalizedString("customTokens.navTitle", comment: "")
        static let chainSection = NSLocalizedString("customTokens.chainSection", comment: "")
        static let chainPickerLabel = NSLocalizedString("customTokens.chainPickerLabel", comment: "")
        static let contractSection = NSLocalizedString("customTokens.contractSection", comment: "")
        static let metadataSection = NSLocalizedString("customTokens.metadataSection", comment: "")
        static let symbolPlaceholder = NSLocalizedString("customTokens.symbolPlaceholder", comment: "")
        static let namePlaceholder = NSLocalizedString("customTokens.namePlaceholder", comment: "")
        static let decimalsPlaceholder = NSLocalizedString("customTokens.decimalsPlaceholder", comment: "")
        static let autoResolve = NSLocalizedString("customTokens.autoResolve", comment: "")
        static let addTokenTitle = NSLocalizedString("customTokens.addTokenTitle", comment: "")
        static let errEvmOnly = NSLocalizedString("customTokens.errEvmOnly", comment: "")

        static func queryFailed(_ desc: String) -> String {
            String(format: NSLocalizedString("customTokens.queryFailed", comment: ""), desc)
        }
    }

    // MARK: - Node errors, shard health, cold signing

    enum NodeErr {
        static let nonceStale = NSLocalizedString("nodeErr.nonceStale", comment: "")
        static let replacementUnderpriced = NSLocalizedString("nodeErr.replacementUnderpriced", comment: "")
        static let underpriced = NSLocalizedString("nodeErr.underpriced", comment: "")
        static let insufficientFunds = NSLocalizedString("nodeErr.insufficientFunds", comment: "")
        static let alreadyKnown = NSLocalizedString("nodeErr.alreadyKnown", comment: "")
        static let gasTooLow = NSLocalizedString("nodeErr.gasTooLow", comment: "")
        static let btcMinRelay = NSLocalizedString("nodeErr.btcMinRelay", comment: "")
        static let btcInputSpent = NSLocalizedString("nodeErr.btcInputSpent", comment: "")
        static let btcAbnormalFee = NSLocalizedString("nodeErr.btcAbnormalFee", comment: "")
        static let solBlockhash = NSLocalizedString("nodeErr.solBlockhash", comment: "")
        static let solRent = NSLocalizedString("nodeErr.solRent", comment: "")
        static let timeout = NSLocalizedString("nodeErr.timeout", comment: "")
        static let cannotConnect = NSLocalizedString("nodeErr.cannotConnect", comment: "")
        static let rateLimited = NSLocalizedString("nodeErr.rateLimited", comment: "")
        static let unauthorized = NSLocalizedString("nodeErr.unauthorized", comment: "")

        static func broadcastFailed(_ tail: String) -> String {
            String(format: NSLocalizedString("nodeErr.broadcastFailedPrefix", comment: ""), tail)
        }
    }

    enum ShardHealth {
        static let title = NSLocalizedString("shardHealth.title", comment: "")
        static let noWalletsTitle = NSLocalizedString("shardHealth.noWalletsTitle", comment: "")
        static let noWalletsSubtitle = NSLocalizedString("shardHealth.noWalletsSubtitle", comment: "")
        static let checking = NSLocalizedString("shardHealth.checking", comment: "")
        static let recheck = NSLocalizedString("shardHealth.recheck", comment: "")
        static let statusNotChecked = NSLocalizedString("shardHealth.statusNotChecked", comment: "")
        static let statusAbnormal = NSLocalizedString("shardHealth.statusAbnormal", comment: "")
        static let statusAllOK = NSLocalizedString("shardHealth.statusAllOK", comment: "")
        static let tapToStart = NSLocalizedString("shardHealth.tapToStart", comment: "")
        static let someUnreadable = NSLocalizedString("shardHealth.someUnreadable", comment: "")
        static let allReadable = NSLocalizedString("shardHealth.allReadable", comment: "")
        static let resMissing = NSLocalizedString("shardHealth.resMissing", comment: "")
        static let resEmpty = NSLocalizedString("shardHealth.resEmpty", comment: "")

        static func lastCheck(_ formatted: String) -> String {
            String(format: NSLocalizedString("shardHealth.lastCheck", comment: ""), formatted)
        }

        static func resOK(_ bytes: Int) -> String {
            String(format: NSLocalizedString("shardHealth.resOK", comment: ""), bytes)
        }

        static func resUnreadable(_ err: String) -> String {
            String(format: NSLocalizedString("shardHealth.resUnreadable", comment: ""), err)
        }
    }

    enum ColdSign {
        static let title = NSLocalizedString("coldSign.title", comment: "")
        static let offlineMode = NSLocalizedString("coldSign.offlineMode", comment: "")
        static let intro = NSLocalizedString("coldSign.intro", comment: "")
        static let stepPrep = NSLocalizedString("coldSign.step.prep", comment: "")
        static let step1of4 = NSLocalizedString("coldSign.step.1of4", comment: "")
        static let step2of4 = NSLocalizedString("coldSign.step.2of4", comment: "")
        static let step3of4 = NSLocalizedString("coldSign.step.3of4", comment: "")
        static let step4of4 = NSLocalizedString("coldSign.step.4of4", comment: "")
        static let stepComplete = NSLocalizedString("coldSign.step.complete", comment: "")
        static let stepFailed = NSLocalizedString("coldSign.step.failed", comment: "")
        static let initializing = NSLocalizedString("coldSign.initializing", comment: "")
        static let generatingQR = NSLocalizedString("coldSign.generatingQR", comment: "")
        static let guideInvite = NSLocalizedString("coldSign.guide.invite", comment: "")
        static let guideRound2 = NSLocalizedString("coldSign.guide.round2", comment: "")
        static let scanPeer = NSLocalizedString("coldSign.scanPeer", comment: "")
        static let promptRound1 = NSLocalizedString("coldSign.prompt.round1", comment: "")
        static let promptRound2 = NSLocalizedString("coldSign.prompt.round2", comment: "")
        static let signSuccess = NSLocalizedString("coldSign.signSuccess", comment: "")
        static let copyHex = NSLocalizedString("coldSign.copyHex", comment: "")
        static let sendBack = NSLocalizedString("coldSign.sendBack", comment: "")
        static let unknownError = NSLocalizedString("coldSign.unknownError", comment: "")
        static let readyToScan = NSLocalizedString("coldSign.readyToScan", comment: "")

        static func sigLength(_ n: Int) -> String {
            String(format: NSLocalizedString("coldSign.sigLength", comment: ""), n)
        }

        // dev.50 — cosigner role
        static let rolePrompt = NSLocalizedString("coldSign.rolePrompt", comment: "")
        static let roleInitiator = NSLocalizedString("coldSign.roleInitiator", comment: "")
        static let roleCosigner = NSLocalizedString("coldSign.roleCosigner", comment: "")
        static let roleInitiatorHint = NSLocalizedString("coldSign.roleInitiatorHint", comment: "")
        static let roleCosignerHint = NSLocalizedString("coldSign.roleCosignerHint", comment: "")
        static let promptInvite = NSLocalizedString("coldSign.prompt.invite", comment: "")
        static let promptInitiatorRound2 = NSLocalizedString("coldSign.prompt.initiatorRound2", comment: "")
        static let guideCosignerRound1 = NSLocalizedString("coldSign.guide.cosignerRound1", comment: "")
        static let guideCosignerRound2 = NSLocalizedString("coldSign.guide.cosignerRound2", comment: "")
        static let cosignerStep1of3 = NSLocalizedString("coldSign.step.cosigner1of3", comment: "")
        static let cosignerStep2of3 = NSLocalizedString("coldSign.step.cosigner2of3", comment: "")
        static let cosignerStep3of3 = NSLocalizedString("coldSign.step.cosigner3of3", comment: "")
        static let cosignerComplete = NSLocalizedString("coldSign.cosigner.complete", comment: "")
    }

    // dev.73 — v2 multi-party ceremony strings
    enum ColdSignV2 {
        static let title = NSLocalizedString("coldSignV2.title", comment: "")
        static let experimentalBadge = NSLocalizedString("coldSignV2.experimental", comment: "")
        static let waitingInvite = NSLocalizedString("coldSignV2.waitingInvite", comment: "")
        static let signatureReady = NSLocalizedString("coldSignV2.signatureReady", comment: "")
        static let cosignerHasSignature = NSLocalizedString("coldSignV2.cosignerHasSignature", comment: "")
        static let intro = NSLocalizedString("coldSignV2.intro", comment: "")

        static func showToPeer(_ peer: String, _ step: Int) -> String {
            String(format: NSLocalizedString("coldSignV2.showToPeer", comment: ""), peer, step)
        }
        static func scanFromPeer(_ peer: String) -> String {
            String(format: NSLocalizedString("coldSignV2.scanFromPeer", comment: ""), peer)
        }
    }
}

// MARK: - dev.47 (TxHistory + WalletHome residual + Settings residual)

extension L10n {
    enum RBFSheet {
        static let title = NSLocalizedString("rbfSheet.title", comment: "")
        static let explain = NSLocalizedString("rbfSheet.explain", comment: "")
        static let availableOps = NSLocalizedString("rbfSheet.availableOps", comment: "")
        static let op1 = NSLocalizedString("rbfSheet.op1", comment: "")
        static let op2 = NSLocalizedString("rbfSheet.op2", comment: "")
        static let op3 = NSLocalizedString("rbfSheet.op3", comment: "")
        static let discardAndResign = NSLocalizedString("rbfSheet.discardAndResign", comment: "")
        static let navTitle = NSLocalizedString("rbfSheet.navTitle", comment: "")
        static let close = NSLocalizedString("rbfSheet.close", comment: "")
    }

    enum WalletEmpty {
        static let startUsing = NSLocalizedString("walletEmpty.startUsing", comment: "")
        static let copied = NSLocalizedString("walletEmpty.copied", comment: "")
        static let copyAddress = NSLocalizedString("walletEmpty.copyAddress", comment: "")
        static let showQR = NSLocalizedString("walletEmpty.showQR", comment: "")
        static let addCustomToken = NSLocalizedString("walletEmpty.addCustomToken", comment: "")
        static let totalAssets = NSLocalizedString("walletEmpty.totalAssets", comment: "")
        static let removeFromDevice = NSLocalizedString("walletEmpty.removeFromDevice", comment: "")

        static func recvHint(_ symbol: String) -> String {
            String(format: NSLocalizedString("walletEmpty.recvHint", comment: ""), symbol)
        }
        static func summaryOneAccount(_ chains: Int) -> String {
            String(format: NSLocalizedString("walletEmpty.summaryOneAccount", comment: ""), chains)
        }
        static func summaryMultiAccount(_ accts: Int, _ chains: Int) -> String {
            String(format: NSLocalizedString("walletEmpty.summaryMultiAccount", comment: ""), accts, chains)
        }
    }

    enum SettingsResidual {
        static let languageSection = NSLocalizedString("settingsR.languageSection", comment: "")
        static let languageRowTitle = NSLocalizedString("settingsR.languageRowTitle", comment: "")
        static let deviceNickname = NSLocalizedString("settingsR.deviceNickname", comment: "")
        static let deviceNicknameHint = NSLocalizedString("settingsR.deviceNicknameHint", comment: "")
        static let hwWalletTitle = NSLocalizedString("settingsR.hwWalletTitle", comment: "")
        static let hwWalletBody = NSLocalizedString("settingsR.hwWalletBody", comment: "")
        static let hwWalletSubtitle = NSLocalizedString("settingsR.hwWalletSubtitle", comment: "")
        static let langZh = NSLocalizedString("settingsR.langZh", comment: "")
        static let pinWeak = NSLocalizedString("settingsR.pinWeak", comment: "")
        static let pinMedium = NSLocalizedString("settingsR.pinMedium", comment: "")
        static let pinStrong = NSLocalizedString("settingsR.pinStrong", comment: "")
        static let pinVeryStrong = NSLocalizedString("settingsR.pinVeryStrong", comment: "")
        static let replaceTitle = NSLocalizedString("settingsR.replaceTitle", comment: "")
        static let replaceIntro = NSLocalizedString("settingsR.replaceIntro", comment: "")
        static let step1Title = NSLocalizedString("settingsR.step1Title", comment: "")
        static let step1Body = NSLocalizedString("settingsR.step1Body", comment: "")
        static let step2Title = NSLocalizedString("settingsR.step2Title", comment: "")
        static let step2Body = NSLocalizedString("settingsR.step2Body", comment: "")
        static let step3Title = NSLocalizedString("settingsR.step3Title", comment: "")
        static let step3Body = NSLocalizedString("settingsR.step3Body", comment: "")
        static let step4Title = NSLocalizedString("settingsR.step4Title", comment: "")
        static let step4Body = NSLocalizedString("settingsR.step4Body", comment: "")
        static let comingSoon = NSLocalizedString("settingsR.comingSoon", comment: "")
        static let refreshShardsComingSoon = NSLocalizedString("settingsR.refreshShardsComingSoon", comment: "")
        static let replaceNavTitle = NSLocalizedString("settingsR.replaceNavTitle", comment: "")
        static let rotateExplanationTitle = NSLocalizedString("settingsR.rotateExplanationTitle", comment: "")
        static let rotateExplanationBody = NSLocalizedString("settingsR.rotateExplanationBody", comment: "")
        static let lostDeviceSectionTitle = NSLocalizedString("settingsR.lostDeviceSectionTitle", comment: "")
    }

    enum SettingsAppearance {
        static let section          = NSLocalizedString("settingsAppearance.section",          value: "Appearance",       comment: "")
        static let displayMode      = NSLocalizedString("settingsAppearance.displayMode",      value: "Display mode",     comment: "")
        static let modeStandard     = NSLocalizedString("settingsAppearance.modeStandard",     value: "Standard",         comment: "")
        static let modeVault        = NSLocalizedString("settingsAppearance.modeVault",        value: "Vault",            comment: "")
        static let hideBalances     = NSLocalizedString("settingsAppearance.hideBalances",     value: "Hide balances by default", comment: "")
        static let hideBalancesHint = NSLocalizedString("settingsAppearance.hideBalancesHint", value: "Show ••• until revealed", comment: "")
        static let envTag           = NSLocalizedString("settingsAppearance.envTag",           value: "Environment tag",  comment: "")
        static let envTagHint       = NSLocalizedString("settingsAppearance.envTagHint",       value: "Show PROD / TESTNET label on vault rows", comment: "")
    }

    enum Rotate {
        static let nudgeTitle = NSLocalizedString("rotate.nudgeTitle", comment: "")
        static let nudgeBodyNever = NSLocalizedString("rotate.nudgeBodyNever", comment: "")
        static func nudgeBodyDays(_ days: Int) -> String {
            String(format: NSLocalizedString("rotate.nudgeBodyDays", comment: ""), days)
        }
        static let nudgeCTA = NSLocalizedString("rotate.nudgeCTA", comment: "")
        static let nudgeDismiss = NSLocalizedString("rotate.nudgeDismiss", comment: "")
    }

    enum WalletAvatar {
        static let pickerTitle = NSLocalizedString("walletAvatar.pickerTitle", comment: "")
        static let color = NSLocalizedString("walletAvatar.color", comment: "")
        static let icon = NSLocalizedString("walletAvatar.icon", comment: "")
        static let reset = NSLocalizedString("walletAvatar.reset", comment: "")
        static let editMenu = NSLocalizedString("walletAvatar.editMenu", comment: "")
    }

    // MARK: - dev.48 additions

    enum SigningExtra {
        static let speedSlow = NSLocalizedString("signingX.speedSlow", comment: "")
        static let speedNormal = NSLocalizedString("signingX.speedNormal", comment: "")
        static let speedFast = NSLocalizedString("signingX.speedFast", comment: "")
        static let speedCustom = NSLocalizedString("signingX.speedCustom", comment: "")
        static let nativeTokenSuffix = NSLocalizedString("signingX.nativeTokenSuffix", comment: "")
        static let gasPriceGwei = NSLocalizedString("signingX.gasPriceGwei", comment: "")
        static let ensResolveFailed = NSLocalizedString("signingX.ensResolveFailed", comment: "")
        static let bioFailedIcon = NSLocalizedString("signingX.bioFailedIcon", comment: "")
        static let tokenTransferTRC20 = NSLocalizedString("signingX.tokenTransferTRC20", comment: "")
        static let tokenTransferSPL = NSLocalizedString("signingX.tokenTransferSPL", comment: "")
        static let tokenTransferERC20 = NSLocalizedString("signingX.tokenTransferERC20", comment: "")
        static let broadcastFailTronSigMissing = NSLocalizedString("signingX.broadcastFailTronSigMissing", comment: "")

        static func feeTRXEnergy(_ trx: Double, _ energy: UInt64) -> String {
            String(format: NSLocalizedString("signingX.feeTRXEnergy", comment: ""), trx, energy)
        }
        static func broadcastFailed(_ msg: String) -> String {
            String(format: NSLocalizedString("signingX.broadcastFailed", comment: ""), msg)
        }
    }

    enum OnboardingCards {
        static let card1Title = NSLocalizedString("onb.card1Title", comment: "")
        static let card1Subtitle = NSLocalizedString("onb.card1Subtitle", comment: "")
        static let card2Title = NSLocalizedString("onb.card2Title", comment: "")
        static let card2Subtitle = NSLocalizedString("onb.card2Subtitle", comment: "")
        static let card3Title = NSLocalizedString("onb.card3Title", comment: "")
        static let card3Subtitle = NSLocalizedString("onb.card3Subtitle", comment: "")
        static let continueBtn = NSLocalizedString("onb.continueBtn", comment: "")
    }

    enum ShardsVM {
        static let pinRequired = NSLocalizedString("shardsVM.pinRequired", comment: "")
        static let pinWrong = NSLocalizedString("shardsVM.pinWrong", comment: "")
        static let icloudRKUnavailable = NSLocalizedString("shardsVM.icloudRKUnavailable", comment: "")
        static let encModeICloudRK = NSLocalizedString("shardsVM.encModeICloudRK", comment: "")
        static let encModePIN = NSLocalizedString("shardsVM.encModePIN", comment: "")

        static func exportedSummary(_ chains: Int, _ bytes: Int, _ mode: String) -> String {
            let key = chains > 1 ? "shardsVM.exportedSummaryPlural" : "shardsVM.exportedSummary"
            return String(format: NSLocalizedString(key, comment: ""), chains, bytes, mode)
        }
    }

    enum BackupCrypto {
        static let decryptFailed = NSLocalizedString("backupCrypto.decryptFailed", comment: "")

        static func unsupportedVersion(_ v: Any) -> String {
            String(format: NSLocalizedString("backupCrypto.unsupportedVersion", comment: ""), "\(v)")
        }
        static func malformed(_ m: String) -> String {
            String(format: NSLocalizedString("backupCrypto.malformed", comment: ""), m)
        }
    }

    enum ColdSignErr {
        static let mvpOnly2of2 = NSLocalizedString("coldSignErr.mvpOnly2of2", comment: "")
        static let signatureMissing = NSLocalizedString("coldSignErr.signatureMissing", comment: "")
        static let walletMismatch = NSLocalizedString("coldSignErr.walletMismatch", comment: "")

        static func qrMismatchPhase(_ phase: String) -> String {
            String(format: NSLocalizedString("coldSignErr.qrMismatchPhase", comment: ""), phase)
        }
    }

    enum ReceiveExtra {
        static let requestAmount = NSLocalizedString("receiveX.requestAmount", comment: "")
        static let optional = NSLocalizedString("receiveX.optional", comment: "")
    }

    enum CustomTokensExtra {
        static let solanaMintPlaceholder = NSLocalizedString("customTokensX.solanaMintPlaceholder", comment: "")
    }
}

// MARK: - dev.52 additions (key refresh)

extension L10n {
    enum Refresh {
        static let title = NSLocalizedString("refresh.title", comment: "")
        static func subtitle(_ name: String) -> String {
            String(format: NSLocalizedString("refresh.subtitle", comment: ""), name)
        }
        static let explainer = NSLocalizedString("refresh.explainer", comment: "")
        static let idle = NSLocalizedString("refresh.idle", comment: "")
        static let waitingPeer = NSLocalizedString("refresh.waitingPeer", comment: "")
        static let waitingPeerHintTitle = NSLocalizedString("refresh.waitingPeerHintTitle", comment: "")
        static let waitingPeerHintBody = NSLocalizedString("refresh.waitingPeerHintBody", comment: "")
        static let connectTitle = NSLocalizedString("refresh.connectTitle", comment: "")
        static let connectHint = NSLocalizedString("refresh.connectHint", comment: "")
        static let roomCodeHint = NSLocalizedString("refresh.roomCodeHint", comment: "")
        static func runningRound(_ done: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("refresh.runningRound", comment: ""), done, total)
        }
        static let persisting = NSLocalizedString("refresh.persisting", comment: "")
        static let complete = NSLocalizedString("refresh.complete", comment: "")
        static let errorTitle = NSLocalizedString("refresh.errorTitle", comment: "")
        static let errorNonNofN = NSLocalizedString("refresh.errorNonNofN", comment: "")
        static let errorNeedsPin = NSLocalizedString("refresh.errorNeedsPin", comment: "")
        static let startButton = NSLocalizedString("refresh.startButton", comment: "")
        static let pinTitle = NSLocalizedString("refresh.pinTitle", comment: "")
        static let pinMessage = NSLocalizedString("refresh.pinMessage", comment: "")
        static let pinIncorrect = NSLocalizedString("refresh.pinIncorrect", comment: "")
        static let unlock = NSLocalizedString("refresh.unlock", comment: "")
        static let entryPoint = NSLocalizedString("refresh.entryPoint", comment: "")
        static let entryPointSubtitle = NSLocalizedString("refresh.entryPointSubtitle", comment: "")
    }
}
// swiftlint:enable type_body_length file_length
