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
    }

    // MARK: - Tabs

    enum Tab {
        static let wallet = NSLocalizedString("tab.wallet", comment: "")
        static let shards = NSLocalizedString("tab.shards", comment: "")
        static let settings = NSLocalizedString("tab.settings", comment: "")
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
        static let createNewWallet = NSLocalizedString("walletHome.createNewWallet", comment: "")
        static let opensCreationFlow = NSLocalizedString("walletHome.opensCreationFlow", comment: "")
        static let startMPCHint = NSLocalizedString("walletHome.startMPCHint", comment: "")
        static let viewDetailsHint = NSLocalizedString("walletHome.viewDetailsHint", comment: "")
        static let editWalletList = NSLocalizedString("walletHome.editWalletList", comment: "")
        static let pendingBroadcasts = NSLocalizedString("walletHome.pendingBroadcasts", comment: "")
        static let loadingBalance = NSLocalizedString("walletHome.loadingBalance", comment: "")

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

        static func networkWarning(_ chains: String) -> String {
            String(format: NSLocalizedString("walletHome.networkWarning", comment: ""), chains)
        }
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
        static let noTokensDescription = NSLocalizedString("walletDetail.noTokensDescription", comment: "")
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

        static func sendSymbol(_ symbol: String) -> String {
            String(format: NSLocalizedString("txHistory.sendSymbol", comment: ""), symbol)
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
        static let nextInviteCoSigners = NSLocalizedString("signing.nextInviteCoSigners", comment: "")
        static let inviteHint = NSLocalizedString("signing.inviteHint", comment: "")
        static let inviteCoSigners = NSLocalizedString("signing.inviteCoSigners", comment: "")
        static let waitingForCoSigners = NSLocalizedString("signing.waitingForCoSigners", comment: "")
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

        static func roundOf(_ current: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("signing.roundOf", comment: ""), current, total)
        }

        static func signingRound(_ current: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("signing.signingRound", comment: ""), current, total)
        }

        static func broadcastingTo(_ chain: String) -> String {
            String(format: NSLocalizedString("signing.broadcastingTo", comment: ""), chain)
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

        static let transportPreferences = NSLocalizedString("settings.transportPreferences", comment: "")
        static let transportHint = NSLocalizedString("settings.transportHint", comment: "")
        static let about = NSLocalizedString("settings.about", comment: "")
        static let version = NSLocalizedString("settings.version", comment: "")
        static let coreLibrary = NSLocalizedString("settings.coreLibrary", comment: "")
        static let mpcProtocols = NSLocalizedString("settings.mpcProtocols", comment: "")
        static let e2eEncryption = NSLocalizedString("settings.e2eEncryption", comment: "")
        static let secureEnclave = NSLocalizedString("settings.secureEnclave", comment: "")
        static let hardwareProtected = NSLocalizedString("settings.hardwareProtected", comment: "")
        static let softwareOnly = NSLocalizedString("settings.softwareOnly", comment: "")
        static let openSourceLicenses = NSLocalizedString("settings.openSourceLicenses", comment: "")
        static let licensesHint = NSLocalizedString("settings.licensesHint", comment: "")
        static let dangerZone = NSLocalizedString("settings.dangerZone", comment: "")
        static let wipeAllData = NSLocalizedString("settings.wipeAllData", comment: "")
        static let wipeHint = NSLocalizedString("settings.wipeHint", comment: "")
        static let wipeConfirmTitle = NSLocalizedString("settings.wipeConfirmTitle", comment: "")
        static let wipeEverything = NSLocalizedString("settings.wipeEverything", comment: "")
        static let wipeMessage = NSLocalizedString("settings.wipeMessage", comment: "")
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
        static let configureInfo = NSLocalizedString("nodeSettings.configureInfo", comment: "")
        static let ethereumEVM = NSLocalizedString("nodeSettings.ethereumEVM", comment: "")
        static let rpcURL = NSLocalizedString("nodeSettings.rpcURL", comment: "")
        static let networkPicker = NSLocalizedString("nodeSettings.networkPicker", comment: "")
        static let mainnet = NSLocalizedString("nodeSettings.mainnet", comment: "")
        static let sepoliaTestnet = NSLocalizedString("nodeSettings.sepoliaTestnet", comment: "")
        static let polygon = NSLocalizedString("nodeSettings.polygon", comment: "")
        static let arbitrumOne = NSLocalizedString("nodeSettings.arbitrumOne", comment: "")
        static let base = NSLocalizedString("nodeSettings.base", comment: "")
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
    }

    // MARK: - Node Status

    enum NodeStatus {
        static let notChecked = NSLocalizedString("nodeStatus.notChecked", comment: "")
        static let connected = NSLocalizedString("nodeStatus.connected", comment: "")
        static let checking = NSLocalizedString("nodeStatus.checking", comment: "")
    }

    // MARK: - Licenses

    enum Licenses {
        static let title = NSLocalizedString("licenses.title", comment: "")
        static let coreDependencies = NSLocalizedString("licenses.coreDependencies", comment: "")
    }

    // MARK: - Cold Signing

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
    }
}

// swiftlint:enable type_body_length file_length
