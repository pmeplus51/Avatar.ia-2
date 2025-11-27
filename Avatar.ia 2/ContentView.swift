//
//  ContentView.swift
//  Avatar.ia 2
//
//  Created by Théophile toulemonde on 21/11/2025.
//  Updated: MainTabView avec barre d'onglets + emojis
//

import SwiftUI
import AVKit
import UIKit
import AuthenticationServices
import StoreKit

fileprivate let brandAccentColor = Color(red: 0.35, green: 0.75, blue: 1.0)

final class GenerationStore: ObservableObject {
    @Published var history: [GeneratedVideo] = []
    
    func add(video url: String, prompt: String, format: VideoFormat, duration: VideoDuration) {
        let item = GeneratedVideo(url: url, prompt: prompt, format: format, duration: duration, date: Date())
        history.insert(item, at: 0)
    }
    
    func clear() {
        history.removeAll()
    }
}

struct GeneratedVideo: Identifiable {
    let id = UUID()
    let url: String
    let prompt: String
    let format: VideoFormat
    let duration: VideoDuration
    let date: Date
}

final class UserSession: ObservableObject {
    private enum StorageKey {
        static let isSignedIn = "userSession.isSignedIn"
        static let currentUserID = "userSession.currentUserID"
        static let accounts = "userSession.accounts"
    }
    
    private struct AccountSnapshot: Codable {
        var email: String
        var credits: Int
        var hasActiveSubscription: Bool
        var nextRewardTimestamp: TimeInterval?
    }
    
    @Published var isSignedIn = false { didSet { persistSessionFlags() } }
    @Published var email = "" { didSet { persistAccountData() } }
    @Published var credits = 0 { didSet { persistAccountData() } }
    @Published var hasActiveSubscription = false { didSet { persistAccountData() } }
    @Published var nextRewardDate: Date? = nil { didSet { persistAccountData() } }
    
    private var accounts: [String: AccountSnapshot] = [:]
    private var currentUserID: String? { didSet { persistSessionFlags() } }
    private var isRestoringState = true
    
    init() {
        restore()
        isRestoringState = false
    }
    
    var initials: String {
        guard let firstChar = email.first else { return "NA" }
        return String(firstChar).uppercased()
    }
    
    var userID: String? {
        return currentUserID
    }
    
    func handleSignIn(userID: String, email providedEmail: String?) {
        isRestoringState = true
        currentUserID = userID
        let resolvedEmail: String
        if let providedEmail, !providedEmail.isEmpty {
            resolvedEmail = providedEmail
        } else if let snapshot = accounts[userID]?.email {
            resolvedEmail = snapshot
        } else {
            resolvedEmail = "\(userID)@apple.com"
        }
        email = resolvedEmail
        
        if let snapshot = accounts[userID] {
            credits = snapshot.credits
            hasActiveSubscription = snapshot.hasActiveSubscription
            if let ts = snapshot.nextRewardTimestamp {
                nextRewardDate = Date(timeIntervalSince1970: ts)
            } else {
                nextRewardDate = nil
            }
        } else {
            credits = 0
            hasActiveSubscription = false
            nextRewardDate = nil
        }
        isRestoringState = false
        isSignedIn = true
        persistAccountData()
    }
    
    func signOut() {
        persistAccountData()
        isRestoringState = true
        isSignedIn = false
        currentUserID = nil
        email = ""
        credits = 0
        hasActiveSubscription = false
        nextRewardDate = nil
        isRestoringState = false
    }
    
    func addCredits(_ amount: Int) {
        credits += amount
    }
    
    private func persistAccountData() {
        guard !isRestoringState else { return }
        guard let userID = currentUserID else { return }
        var snapshot = accounts[userID] ?? AccountSnapshot(email: email, credits: credits, hasActiveSubscription: hasActiveSubscription, nextRewardTimestamp: nextRewardDate?.timeIntervalSince1970)
        snapshot.email = email
        snapshot.credits = credits
        snapshot.hasActiveSubscription = hasActiveSubscription
        snapshot.nextRewardTimestamp = nextRewardDate?.timeIntervalSince1970
        accounts[userID] = snapshot
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: StorageKey.accounts)
        }
    }
    
    private func persistSessionFlags() {
        guard !isRestoringState else { return }
        let defaults = UserDefaults.standard
        defaults.set(isSignedIn, forKey: StorageKey.isSignedIn)
        defaults.set(currentUserID, forKey: StorageKey.currentUserID)
    }
    
    private func restore() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: StorageKey.accounts),
           let decoded = try? JSONDecoder().decode([String: AccountSnapshot].self, from: data) {
            accounts = decoded
        }
        
        isSignedIn = defaults.bool(forKey: StorageKey.isSignedIn)
        currentUserID = defaults.string(forKey: StorageKey.currentUserID)
        
        guard let userID = currentUserID,
              let snapshot = accounts[userID] else {
            email = ""
            credits = 0
            hasActiveSubscription = false
            nextRewardDate = nil
            isSignedIn = false
            return
        }
        
        email = snapshot.email
        credits = snapshot.credits
        hasActiveSubscription = snapshot.hasActiveSubscription
        if let timestamp = snapshot.nextRewardTimestamp {
            nextRewardDate = Date(timeIntervalSince1970: timestamp)
        } else {
            nextRewardDate = nil
        }
    }
}

@MainActor
final class StoreManager: ObservableObject {
    enum ProductType: String, CaseIterable {
        case subscription = "avatar.pmeplus.app.premium"
        case pack2k = "avatar.pmeplus.app.2kpack"
        case pack5k = "avatar.pmeplus.app.5k"
        case pack10k = "avatar.pmeplus.app.10kpack"
    }
    
    @Published var products: [Product] = []
    @Published var purchaseMessage: String?
    @Published var isLoadingProducts = false
    
    private enum StorageKey {
        static let processedTransactions = "storeManager.processedTransactions"
    }
    
    // Stocker les IDs de transaction déjà traités (par userID)
    private var processedTransactions: [String: Set<UInt64>] = [:]
    
    private var transactionListenerTask: Task<Void, Never>?
    
    // Mode production : récompense toutes les 7 journées (pas de mode debug actif)
    private let rewardInterval: TimeInterval = 7 * 24 * 60 * 60
    
    init() {
        loadProcessedTransactions()
    }
    
    private func loadProcessedTransactions() {
        if let data = UserDefaults.standard.data(forKey: StorageKey.processedTransactions),
           let decoded = try? JSONDecoder().decode([String: [UInt64]].self, from: data) {
            processedTransactions = decoded.mapValues { Set($0) }
        }
    }
    
    private func saveProcessedTransactions() {
        let encoded = processedTransactions.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: StorageKey.processedTransactions)
        }
    }
    
    private func isTransactionProcessed(_ transactionID: UInt64, for userID: String) -> Bool {
        return processedTransactions[userID]?.contains(transactionID) ?? false
    }
    
    private func markTransactionAsProcessed(_ transactionID: UInt64, for userID: String) {
        if processedTransactions[userID] == nil {
            processedTransactions[userID] = []
        }
        processedTransactions[userID]?.insert(transactionID)
        saveProcessedTransactions()
    }
    
    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoadingProducts = true
        do {
            let loaded = try await Product.products(for: ProductType.allCases.map { $0.rawValue })
            products = loaded.sorted { $0.displayName < $1.displayName }
        } catch {
            purchaseMessage = "Impossible de charger les produits (\(error.localizedDescription))"
        }
        isLoadingProducts = false
    }
    
    func product(for type: ProductType) -> Product? {
        products.first { $0.id == type.rawValue }
    }
    
    func purchase(_ type: ProductType, session: UserSession) async {
        guard let product = product(for: type) else {
            purchaseMessage = "Produit introuvable."
            return
        }
        
        if type != .subscription && !session.hasActiveSubscription {
            purchaseMessage = "Vous devez d'abord activer l'abonnement pour acheter un pack de crédits."
            return
        }
        
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                try await handleVerifiedTransaction(verification, session: session)
            case .pending:
                purchaseMessage = "Paiement en attente de validation."
            case .userCancelled:
                purchaseMessage = "Achat annulé."
            @unknown default:
                purchaseMessage = "Achat inachevé."
            }
        } catch {
            purchaseMessage = "Achat impossible : \(error.localizedDescription)"
        }
    }
    
    private func handleVerifiedTransaction(_ result: StoreKit.VerificationResult<StoreKit.Transaction>, session: UserSession) async throws {
        let transaction: StoreKit.Transaction = try checkVerified(result)
        let transactionID = transaction.id
        guard let userID = session.userID else {
            await transaction.finish()
            return
        }
        
        switch transaction.productID {
        case ProductType.subscription.rawValue:
            let hasRevocationDate = transaction.revocationDate != nil
            let isExpired = transaction.expirationDate != nil && transaction.expirationDate! < Date()
            let isActive = !hasRevocationDate && !isExpired
            let wasActive = session.hasActiveSubscription
            session.hasActiveSubscription = isActive
            
            #if DEBUG
            print("🔍 [DEBUG] Transaction abonnement - isActive: \(isActive), wasActive: \(wasActive), revocationDate: \(transaction.revocationDate?.description ?? "nil"), expirationDate: \(transaction.expirationDate?.description ?? "nil"), isExpired: \(isExpired)")
            #endif
            
            if isActive && !wasActive {
                session.addCredits(1000)
                // Utiliser le délai debug (1 minute) ou normal (7 jours)
                session.nextRewardDate = Calendar.current.date(byAdding: .second, value: Int(rewardInterval), to: Date())
                purchaseMessage = "Abonnement activé, 1000 crédits ajoutés."
                #if DEBUG
                print("🔍 [DEBUG] ✅ Abonnement activé - 1000 crédits ajoutés, prochaine récompense dans \(Int(rewardInterval))s")
                #endif
            } else if !isActive {
                purchaseMessage = "Abonnement résilié."
                #if DEBUG
                print("🔍 [DEBUG] ⚠️ Abonnement résilié détecté")
                #endif
            } else {
                purchaseMessage = "Abonnement déjà actif."
            }
        case ProductType.pack2k.rawValue:
            // Vérifier si la transaction a déjà été traitée
            if isTransactionProcessed(transactionID, for: userID) {
                purchaseMessage = "Ce pack a déjà été acheté."
            } else {
                session.addCredits(2000)
                markTransactionAsProcessed(transactionID, for: userID)
                purchaseMessage = "Pack 2000 crédits ajouté."
            }
        case ProductType.pack5k.rawValue:
            if isTransactionProcessed(transactionID, for: userID) {
                purchaseMessage = "Ce pack a déjà été acheté."
            } else {
                session.addCredits(5000)
                markTransactionAsProcessed(transactionID, for: userID)
                purchaseMessage = "Pack 5000 crédits ajouté."
            }
        case ProductType.pack10k.rawValue:
            if isTransactionProcessed(transactionID, for: userID) {
                purchaseMessage = "Ce pack a déjà été acheté."
            } else {
                session.addCredits(10000)
                markTransactionAsProcessed(transactionID, for: userID)
                purchaseMessage = "Pack 10000 crédits ajouté."
            }
        default:
            break
        }
        await transaction.finish()
    }
    
    func startListeningForTransactions(session: UserSession) {
        guard transactionListenerTask == nil else { return }
        transactionListenerTask = Task {
            for await result in StoreKit.Transaction.updates {
                do {
                    try await handleVerifiedTransaction(result, session: session)
                } catch {
                    purchaseMessage = "Erreur de mise à jour des achats."
                }
            }
        }
    }
    
    private func checkVerified<T>(_ result: StoreKit.VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
    
    func refreshSubscriptionStatus(session: UserSession) async {
        // Initialiser à false, on le mettra à true seulement si on trouve un abonnement actif
        var foundActiveSubscription = false
        var foundAnySubscription = false
        var foundRevokedSubscription = false
        
        #if DEBUG
        print("🔍 [DEBUG] refreshSubscriptionStatus - Début de la vérification...")
        #endif
        
        // Vérifier les entitlements actuels
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            switch entitlement {
            case .unverified:
                #if DEBUG
                print("🔍 [DEBUG] refreshSubscriptionStatus - Transaction non vérifiée ignorée")
                #endif
                continue
            case .verified(let transaction):
                foundAnySubscription = true
                if transaction.productID == ProductType.subscription.rawValue {
                    let hasRevocationDate = transaction.revocationDate != nil
                    let isExpired = transaction.expirationDate != nil && transaction.expirationDate! < Date()
                    
                    // Un abonnement est actif seulement s'il n'est pas révoqué ET pas expiré
                    let isActive = !hasRevocationDate && !isExpired
                    
                    if hasRevocationDate {
                        foundRevokedSubscription = true
                    }
                    
                    if isActive {
                        foundActiveSubscription = true
                    }
                    
                    #if DEBUG
                    print("🔍 [DEBUG] refreshSubscriptionStatus - Abonnement trouvé:")
                    print("   - productID: \(transaction.productID)")
                    print("   - revocationDate: \(transaction.revocationDate?.description ?? "nil")")
                    print("   - expirationDate: \(transaction.expirationDate?.description ?? "nil")")
                    print("   - isExpired: \(isExpired)")
                    print("   - isActive: \(isActive)")
                    #endif
                } else {
                    #if DEBUG
                    print("🔍 [DEBUG] refreshSubscriptionStatus - Transaction trouvée mais pas un abonnement: \(transaction.productID)")
                    #endif
                }
            }
        }
        
        // Si on avait un abonnement avant mais qu'on ne trouve plus d'entitlement actif,
        // et qu'on trouve une transaction révoquée, alors l'abonnement est résilié
        let previousStatus = session.hasActiveSubscription
        
        // Si on trouve une transaction révoquée, l'abonnement est définitivement résilié
        if foundRevokedSubscription {
            foundActiveSubscription = false
        }
        
        // Mettre à jour le statut : false si aucun abonnement actif trouvé
        session.hasActiveSubscription = foundActiveSubscription
        
        #if DEBUG
        if !foundAnySubscription {
            print("🔍 [DEBUG] refreshSubscriptionStatus - ⚠️ AUCUN entitlement trouvé dans StoreKit (abonnement résilié ou jamais acheté)")
        }
        if foundRevokedSubscription {
            print("🔍 [DEBUG] refreshSubscriptionStatus - ⚠️ Transaction révoquée détectée - Abonnement résilié")
        }
        print("🔍 [DEBUG] refreshSubscriptionStatus - Statut: \(previousStatus ? "ACTIF" : "INACTIF") → \(foundActiveSubscription ? "ACTIF" : "RÉSILIÉ/INACTIF")")
        #endif
    }
    
    func checkWeeklyCreditReward(session: UserSession) async {
        // Vérifier d'abord le statut réel de l'abonnement via StoreKit
        var isActuallyActive = false
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            switch entitlement {
            case .unverified:
                continue
            case .verified(let transaction):
                if transaction.productID == ProductType.subscription.rawValue {
                    let hasRevocationDate = transaction.revocationDate != nil
                    let isExpired = transaction.expirationDate != nil && transaction.expirationDate! < Date()
                    isActuallyActive = !hasRevocationDate && !isExpired
                    
                    #if DEBUG
                    print("🔍 [DEBUG] Abonnement trouvé - Actif: \(isActuallyActive), RevocationDate: \(transaction.revocationDate?.description ?? "nil"), ExpirationDate: \(transaction.expirationDate?.description ?? "nil"), isExpired: \(isExpired)")
                    #endif
                    break
                }
            }
        }
        
        // Mettre à jour le statut local
        session.hasActiveSubscription = isActuallyActive
        
        #if DEBUG
        print("🔍 [DEBUG] checkWeeklyCreditReward - isActuallyActive: \(isActuallyActive), hasActiveSubscription: \(session.hasActiveSubscription), nextRewardDate: \(session.nextRewardDate?.description ?? "nil")")
        #endif
        
        // Ne créditer QUE si l'abonnement est vraiment actif
        guard isActuallyActive, let nextDate = session.nextRewardDate else {
            #if DEBUG
            print("🔍 [DEBUG] Pas de crédits - Abonnement inactif ou pas de date de récompense")
            #endif
            return
        }
        
        let now = Date()
        guard now >= nextDate else {
            #if DEBUG
            let timeRemaining = nextDate.timeIntervalSince(now)
            print("🔍 [DEBUG] Pas encore le moment - Temps restant: \(Int(timeRemaining)) secondes")
            #endif
            return
        }
        
        // Calculer le nombre de périodes (semaines) écoulées
        let timeInterval = now.timeIntervalSince(nextDate)
        let periodsElapsed = Int(timeInterval / rewardInterval)
        
        #if DEBUG
        print("🔍 [DEBUG] Périodes écoulées: \(periodsElapsed), Interval: \(Int(rewardInterval))s, TimeInterval: \(Int(timeInterval))s")
        #endif
        
        guard periodsElapsed > 0 else { return }
        
        // Créditer toutes les périodes manquées (1000 crédits par période)
        let creditsToAdd = periodsElapsed * 1000
        session.addCredits(creditsToAdd)
        
        #if DEBUG
        print("🔍 [DEBUG] ✅ Crédits ajoutés: \(creditsToAdd) (Total: \(session.credits))")
        #endif
        
        // Mettre à jour la date de prochaine récompense
        if let updatedDate = Calendar.current.date(byAdding: .second, value: Int(rewardInterval) * (periodsElapsed + 1), to: nextDate) {
            session.nextRewardDate = updatedDate
        } else {
            // Fallback : ajouter une semaine complète à partir de maintenant
            session.nextRewardDate = Calendar.current.date(byAdding: .second, value: Int(rewardInterval), to: now)
        }
        
        #if DEBUG
        print("🔍 [DEBUG] Prochaine récompense: \(session.nextRewardDate?.description ?? "nil")")
        #endif
    }
}

struct ContentView: View {
    @State private var currentPage = 0
    
    var body: some View {
        ZStack {
            // Fond sombre
            Color.black
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 0) {
                    // Titre Avatar.IA
                    titleSection
                        .padding(.top, 40)
                        .padding(.bottom, 30)
                    
                    // Section Avant/Après
                    beforeAfterSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    
                    // Slogan
                    sloganSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 15)
                    
                    // Description
                    descriptionSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                    
                    // Boutons d'action
                    actionButtons
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                }
            }
        }
    }
    
    // MARK: - Title Section
    private var titleSection: some View {
        HStack(spacing: 0) {
            Text("Avatar")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            Text(".IA")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0)) // Bleu clair
        }
    }
    
    // MARK: - Before/After Section
    private var beforeAfterSection: some View {
        GeometryReader { geometry in
            let cardWidth = (geometry.size.width - 15) / 2
        HStack(spacing: 15) {
            // Panneau Avant
            VStack(spacing: 10) {
                    Image("IMG_6195")
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: 200)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                    RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 8)
                
                Text("Avant")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
                .frame(width: cardWidth)
            
            // Panneau Après
            VStack(spacing: 10) {
                LoopingVideoView(url: Bundle.main.url(forResource: "demo", withExtension: "mp4"))
                    .frame(width: cardWidth, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                    RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 8)
                
                Text("Après")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: cardWidth)
        }
        }
        .frame(height: 230)
    }
    
    // MARK: - Pagination Dots
    private var paginationDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<8) { index in
                Circle()
                    .fill(index == currentPage ? Color(red: 0.35, green: 0.75, blue: 1.0) : Color(red: 0.35, green: 0.75, blue: 1.0).opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
    
    // MARK: - Slogan Section
    private var sloganSection: some View {
        Text("La révolution est là")
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
    
    // MARK: - Description Section
    private var descriptionSection: some View {
        Text("Créez des vidéos ultra-réalistes de vos produits avec une simple photo et un prompt")
            .font(.system(size: 16))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
    
    // MARK: - Action Buttons
    private var actionButtons: some View {
        HStack(spacing: 15) {
            ActionButton(
                emoji: "📂",
                label: "Importez"
            )
            
            ActionButton(
                emoji: "💬",
                label: "Décrivez"
            )
            
            ActionButton(
                emoji: "🎥",
                label: "Générez"
            )
            
            ActionButton(
                emoji: "🛜",
                label: "Déployez"
            )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Action Button Component
struct ActionButton: View {
    var emoji: String
    let label: String
    
    var body: some View {
        Button(action: {
            // Action à implémenter
        }) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                        .frame(width: 70, height: 70)
                    
                    Text(emoji)
                        .font(.system(size: 32))
                }
                
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: .infinity)
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Looping Video View
struct LoopingVideoView: UIViewRepresentable {
    let url: URL?
    
    func makeUIView(context: Context) -> LoopingVideoPlayerView {
        let view = LoopingVideoPlayerView()
        view.configure(with: url)
        return view
    }
    
    func updateUIView(_ uiView: LoopingVideoPlayerView, context: Context) {
        uiView.configure(with: url)
    }
}

final class LoopingVideoPlayerView: UIView {
    private var playerLooper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
    
    func configure(with url: URL?) {
        guard let url = url else { return }
        
        if queuePlayer == nil {
            let playerItem = AVPlayerItem(url: url)
            let queue = AVQueuePlayer(playerItem: playerItem)
            queue.isMuted = true
            queue.play()
            
            let looper = AVPlayerLooper(player: queue, templateItem: playerItem)
            
            let layer = AVPlayerLayer(player: queue)
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
            
            self.queuePlayer = queue
            self.playerLooper = looper
            self.playerLayer = layer
        }
    }
}
// MARK: - Main Tab View
struct MainTabView: View {
    @StateObject private var generationStore = GenerationStore()
    @StateObject private var userSession = UserSession()
    @StateObject private var storeManager = StoreManager()
    
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            TabView(selection: $selectedTab) {
                // Onglet Accueil
                ContentView()
                    .tabItem {
                        Label("Accueil", systemImage: "house.fill")
                    }
                    .tag(0)
                
                // Onglet Créer
                CreateView()
                    .tabItem {
                        Label("Créer", systemImage: "plus.circle.fill")
                    }
                    .tag(1)
                
                // Onglet Abonnement
                SubscriptionView()
                    .tabItem {
                        Label("Abonnement", systemImage: "star.fill")
                    }
                    .tag(2)
                
                // Onglet Profil
                ProfileView()
                    .tabItem {
                        Label("Profil", systemImage: "person.fill")
                    }
                    .tag(3)
            }
            .accentColor(brandAccentColor)
            .gesture(
                DragGesture()
                    .onEnded { value in
                        let threshold: CGFloat = 60
                        if value.translation.width < -threshold {
                            withAnimation {
                                selectedTab = min(selectedTab + 1, 3)
                            }
                        } else if value.translation.width > threshold {
                            withAnimation {
                                selectedTab = max(selectedTab - 1, 0)
                            }
                        }
                    }
            )
        }
        .environmentObject(generationStore)
        .environmentObject(userSession)
        .environmentObject(storeManager)
        .task {
            await storeManager.loadProducts()
            await storeManager.refreshSubscriptionStatus(session: userSession)
            await storeManager.checkWeeklyCreditReward(session: userSession)
            storeManager.startListeningForTransactions(session: userSession)
        }
        .onAppear {
            // Vérifier le statut d'abonnement et les crédits hebdomadaires à chaque ouverture de l'app
            Task {
                await storeManager.refreshSubscriptionStatus(session: userSession)
                await storeManager.checkWeeklyCreditReward(session: userSession)
            }
        }
    }
}

// MARK: - Create View
struct CreateView: View {
    @State private var selectedFormat: VideoFormat = .landscape
    @State private var selectedDuration: VideoDuration = .tenSeconds
    @State private var promptText: String = ""
    @State private var selectedImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isGenerating = false
    @State private var generatedVideoURL: String? = nil
    @State private var errorMessage: String? = nil
    @State private var currentJobId: String? = nil
    @State private var pollingTimer: Timer? = nil
    @State private var generationStartTime: Date? = nil
    @State private var delayWorkItem: DispatchWorkItem? = nil
    @State private var pendingCreditCost = 0
    @State private var activeAlert: AlertItem?
    @State private var downloadAlertMessage = ""
    
    @EnvironmentObject private var generationStore: GenerationStore
    @EnvironmentObject private var userSession: UserSession
    
    private enum StorageKey {
        static let pendingJobId = "pendingJobId"
        static let pendingPrompt = "pendingPrompt"
        static let pendingFormat = "pendingFormat"
        static let pendingDuration = "pendingDuration"
        static let pendingCreditCost = "pendingCreditCost"
        static let pendingImage = "pendingImage"
        static let pendingStartTime = "pendingStartTime"
        static let lastVideoURL = "lastVideoURL"
        static let lastVideoError = "lastVideoError"
    }
    
    private let initialPollingDelay: TimeInterval = 180
    private let pollingInterval: TimeInterval = 30
    private let maxGenerationDuration: TimeInterval = 360
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if userSession.isSignedIn {
                ScrollView {
                    creationStepView
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    
                    myGenerationSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
                .onTapGesture {
                    dismissKeyboard()
                }
            } else {
                LockedSectionView(
                    title: "Connectez-vous pour créer",
                    description: "Accédez à la génération de vidéos et suivez vos créations."
                )
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $selectedImage)
        }
        .alert(item: $activeAlert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
        .onAppear {
            loadPendingGeneration()
            loadLatestVideo()
        }
        .onDisappear {
            stopPolling()
        }
    }
    
    private var creationStepView: some View {
        VStack(spacing: 15) {
            headerSection
                .padding(.top, 10)
            
            photoSection
            
            promptSection
            
            formatSection
            
            durationSection
            
            generateButton
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Générer une vidéo IA")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(brandAccentColor)
                .padding(.horizontal, 20)
            
            Text("Ajoutez une photo de votre produit pour générer une vidéo IA")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 20)
        }
    }
    
    // MARK: - Photo Section
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0))
                Text("Photo du produit")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            Button(action: {
                showImagePicker = true
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 120)
                    
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white.opacity(0.5))
                            Text("Cliquez pour uploader")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Prompt Section
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "video.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0))
                Text("Prompt")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            ZStack(alignment: .topLeading) {
                if promptText.isEmpty {
                    Text("Décrivez votre produit en quelques mots...")
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 12)
                        .padding(.leading, 6)
                }
                textEditorView
            }
            .padding(12)
            .liquidGlass(cornerRadius: 18, tint: brandAccentColor.opacity(0.8))
        }
    }

    @ViewBuilder
    private var textEditorView: some View {
        if #available(iOS 16.0, *) {
            TextEditor(text: $promptText)
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .foregroundColor(.white)
        } else {
            TextEditor(text: $promptText)
                .frame(height: 90)
                .foregroundColor(.white)
        }
    }
    
    // MARK: - Format Section
    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format de la vidéo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            
            HStack(spacing: 12) {
                FormatButton(
                    title: "Format paysage",
                    subtitle: "16:9",
                    icon: "rectangle",
                    isSelected: selectedFormat == .landscape
                ) {
                    selectedFormat = .landscape
                }
                
                FormatButton(
                    title: "Format portrait",
                    subtitle: "9:16",
                    icon: "rectangle.portrait",
                    isSelected: selectedFormat == .portrait
                ) {
                    selectedFormat = .portrait
                }
            }
        }
    }
    
    // MARK: - Duration Section
    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Durée de la vidéo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            
            HStack(spacing: 12) {
                DurationButton(
                    duration: "10s",
                    credits: "50 crédits",
                    isSelected: selectedDuration == .tenSeconds
                ) {
                    selectedDuration = .tenSeconds
                }
                
                DurationButton(
                    duration: "15s",
                    credits: "70 crédits",
                    isSelected: selectedDuration == .fifteenSeconds
                ) {
                    selectedDuration = .fifteenSeconds
                }
            }
        }
    }
    
    // MARK: - Generate Button
    private var generateButton: some View {
        Button(action: {
            generateVideo()
        }) {
            HStack {
                if isGenerating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: 18))
                }
                Text(isGenerating ? "Génération en cours..." : "Générer la vidéo")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .liquidGlass(
                cornerRadius: 18,
                tint: selectedImage != nil ? brandAccentColor : Color.white.opacity(0.25)
            )
        }
        .disabled(selectedImage == nil || isGenerating)
        .opacity(selectedImage == nil ? 0.6 : 1)
    }
    
    // MARK: - My Generation Section
    private var myGenerationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ma génération")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                    .frame(height: 200)
                
                if let videoURL = generatedVideoURL, let url = URL(string: videoURL) {
                    VStack(spacing: 12) {
                        VideoPlayer(player: AVPlayer(url: url))
                            .frame(height: 150)
                            .cornerRadius(12)
                        
                        PrimaryButton(label: "Télécharger", icon: "arrow.down.circle.fill") {
                            downloadVideo(url: videoURL)
                        }
                    }
                } else if let error = errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.red)
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.3))
                        Text("Aucune vidéo générée")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
        }
    }
    
    // MARK: - Video Generation Functions
    private func generateVideo() {
        guard let image = selectedImage else { return }
        let cost = selectedDuration.creditCost
        guard userSession.credits >= cost else {
            activeAlert = AlertItem(
                title: "Crédits insuffisants",
                message: "Il vous faut \(cost) crédits pour cette durée de vidéo. Vous disposez actuellement de \(userSession.credits) crédits."
            )
            return
        }
        
        isGenerating = true
        errorMessage = nil
        generatedVideoURL = nil
        stopPolling()
        pendingCreditCost = cost
        
        // Créer un Job ID unique
        let jobId = UUID().uuidString
        currentJobId = jobId
        generationStartTime = Date()
        
        // Sauvegarder l'état de la génération
        saveGenerationState(jobId: jobId, prompt: promptText, format: selectedFormat, duration: selectedDuration, creditCost: cost, image: image)
        
        // Convertir l'image en base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            errorMessage = "Erreur lors du traitement de l'image"
            isGenerating = false
            return
        }
        let base64Image = imageData.base64EncodedString()
        
        // Préparer les données
        let aspectRatio = selectedFormat == .landscape ? "landscape" : "portrait"
        let callbackUrl = "app://avatar.ia/callback"
        let durationValue = selectedDuration.secondsValue
        
        let body: [String: Any] = [
            "jobId": jobId,
            "prompt": promptText,
            "videoCategory": "sora2",
            "aspectRatio": aspectRatio,
            "startImage": base64Image,
            "duration": durationValue,
            "callbackUrl": callbackUrl
        ]
        
        // Envoyer la requête
        sendGenerationRequest(body: body) { success in
            if success {
                schedulePollingStart(for: jobId)
            } else {
                errorMessage = "Erreur lors de l'envoi de la requête"
                isGenerating = false
                stopPolling()
                pendingCreditCost = 0
                clearGenerationState()
            }
        }
    }
    
    private func sendGenerationRequest(body: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://pmeplus.app.n8n.cloud/webhook/b08a681c-2946-42c3-b99c-7a7825be1aeb") else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(false)
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if error != nil {
                    completion(false)
                } else {
                    completion(true)
                }
            }
        }.resume()
    }
    
    private func schedulePollingStart(for jobId: String, elapsed: TimeInterval = 0) {
        delayWorkItem?.cancel()
        let remainingDelay = initialPollingDelay - elapsed
        
        if remainingDelay <= 0 {
            startPolling(jobId: jobId)
            checkVideoStatus(jobId: jobId)
            return
        }
        
        let workItem = DispatchWorkItem {
            if isGenerating, currentJobId == jobId {
                startPolling(jobId: jobId)
                checkVideoStatus(jobId: jobId)
            }
        }
        delayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay, execute: workItem)
    }
    
    private func startPolling(jobId: String) {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { _ in
            checkVideoStatus(jobId: jobId)
        }
    }
    
    private func checkVideoStatus(jobId: String) {
        guard let startTime = generationStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        
        if elapsed > maxGenerationDuration {
            stopPolling()
            errorMessage = "Temps imparti écoulé, réessayez dans quelques instants"
            isGenerating = false
            clearGenerationState()
            return
        }
        
        guard let url = URL(string: "https://pmeplus.app.n8n.cloud/webhook/55085bf0-02e9-4c2c-a4f2-920834bf320f") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["jobId": jobId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            
            let videoURL = (json["urlVideo"] as? String) ?? (json["URL VIDEO"] as? String)
            let errorMsg = (json["errorMessage"] as? String) ?? (json["ERROR"] as? String)
            
            DispatchQueue.main.async {
                handleGenerationOutcome(videoURL: videoURL, errorMessage: errorMsg)
            }
        }.resume()
    }
    
    private func handleGenerationOutcome(videoURL: String?, errorMessage message: String?) {
        var resolved = false
        var producedVideo = false
        
        if let urlVideo = videoURL, !urlVideo.isEmpty {
            generatedVideoURL = urlVideo
            errorMessage = nil
            saveLatestVideo(url: urlVideo)
            generationStore.add(video: urlVideo, prompt: promptText, format: selectedFormat, duration: selectedDuration)
            producedVideo = true
            resolved = true
        } else if let message = message, !message.isEmpty {
            errorMessage = message
            generatedVideoURL = nil
            saveLatestError(message: message)
            resolved = true
        }
        
        if resolved {
            if producedVideo, pendingCreditCost > 0 {
                userSession.credits = max(0, userSession.credits - pendingCreditCost)
            }
            pendingCreditCost = 0
            isGenerating = false
            stopPolling()
            clearGenerationState()
        }
    }
    
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        delayWorkItem?.cancel()
        delayWorkItem = nil
    }
    
private func downloadVideo(url: String) {
    guard URL(string: url) != nil else { return }
    
    VideoSaver.saveVideo(from: url) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    activeAlert = AlertItem(title: "Téléchargement", message: "Vidéo téléchargée dans votre galerie.")
                case .failure:
                    activeAlert = AlertItem(title: "Téléchargement", message: "Erreur lors du téléchargement.")
                }
            }
        }
    }
    
    // MARK: - State Management
    private func saveGenerationState(jobId: String, prompt: String, format: VideoFormat, duration: VideoDuration, creditCost: Int, image: UIImage) {
        let defaults = UserDefaults.standard
        defaults.set(jobId, forKey: StorageKey.pendingJobId)
        defaults.set(prompt, forKey: StorageKey.pendingPrompt)
        defaults.set(format.storageValue, forKey: StorageKey.pendingFormat)
        defaults.set(duration.secondsValue, forKey: StorageKey.pendingDuration)
        defaults.set(creditCost, forKey: StorageKey.pendingCreditCost)
        if let imageData = image.jpegData(compressionQuality: 0.8) {
            defaults.set(imageData, forKey: StorageKey.pendingImage)
        }
        let startTimestamp = generationStartTime?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        defaults.set(startTimestamp, forKey: StorageKey.pendingStartTime)
    }
    
    private func loadPendingGeneration() {
        let defaults = UserDefaults.standard
        if let jobId = defaults.string(forKey: StorageKey.pendingJobId) {
            currentJobId = jobId
            isGenerating = true
            pendingCreditCost = defaults.integer(forKey: StorageKey.pendingCreditCost)
            
            if let formatValue = defaults.string(forKey: StorageKey.pendingFormat) {
                selectedFormat = formatValue == "landscape" ? .landscape : .portrait
            }
            
            if let durationValue = defaults.object(forKey: StorageKey.pendingDuration) as? Int {
                selectedDuration = durationValue == 10 ? .tenSeconds : .fifteenSeconds
            }
            
            if let prompt = defaults.string(forKey: StorageKey.pendingPrompt) {
                promptText = prompt
            }
            
            if let imageData = defaults.data(forKey: StorageKey.pendingImage),
               let image = UIImage(data: imageData) {
                selectedImage = image
            }
            
            let startTime = defaults.double(forKey: StorageKey.pendingStartTime)
            if startTime > 0 {
                generationStartTime = Date(timeIntervalSince1970: startTime)
                let elapsed = Date().timeIntervalSince1970 - startTime
                if elapsed < maxGenerationDuration {
                    schedulePollingStart(for: jobId, elapsed: elapsed)
                } else {
                    errorMessage = "Temps imparti écoulé, réessayez dans quelques instants"
                    isGenerating = false
                    clearGenerationState()
                }
            }
        }
    }
    
    private func loadLatestVideo() {
        let defaults = UserDefaults.standard
        if let urlKey = userSpecificKey(StorageKey.lastVideoURL),
           let url = defaults.string(forKey: urlKey) {
            generatedVideoURL = url
        }
        if let errorKey = userSpecificKey(StorageKey.lastVideoError),
           let message = defaults.string(forKey: errorKey) {
            errorMessage = message
        }
    }
    
    private func saveLatestVideo(url: String) {
        let defaults = UserDefaults.standard
        if let urlKey = userSpecificKey(StorageKey.lastVideoURL) {
            defaults.set(url, forKey: urlKey)
        }
        if let errorKey = userSpecificKey(StorageKey.lastVideoError) {
            defaults.removeObject(forKey: errorKey)
        }
    }
    
    private func saveLatestError(message: String) {
        let defaults = UserDefaults.standard
        if let errorKey = userSpecificKey(StorageKey.lastVideoError) {
            defaults.set(message, forKey: errorKey)
        }
        if let urlKey = userSpecificKey(StorageKey.lastVideoURL) {
            defaults.removeObject(forKey: urlKey)
        }
    }
    
    private func clearGenerationState() {
        delayWorkItem?.cancel()
        currentJobId = nil
        generationStartTime = nil
        pendingCreditCost = 0
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: StorageKey.pendingJobId)
        defaults.removeObject(forKey: StorageKey.pendingPrompt)
        defaults.removeObject(forKey: StorageKey.pendingFormat)
        defaults.removeObject(forKey: StorageKey.pendingDuration)
        defaults.removeObject(forKey: StorageKey.pendingCreditCost)
        defaults.removeObject(forKey: StorageKey.pendingImage)
        defaults.removeObject(forKey: StorageKey.pendingStartTime)
    }
    
    private func dismissKeyboard() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }
    
    private func userSpecificKey(_ base: String) -> String? {
        guard let userId = userSession.userID, !userId.isEmpty else { return nil }
        return "\(base)_\(userId)"
    }
}

// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Video Format Enum
enum VideoFormat {
    case landscape
    case portrait
    
    var storageValue: String {
        switch self {
        case .landscape: return "landscape"
        case .portrait: return "portrait"
        }
    }
}

// MARK: - Video Duration Enum
enum VideoDuration {
    case tenSeconds
    case fifteenSeconds
    
    var secondsValue: Int {
        switch self {
        case .tenSeconds: return 10
        case .fifteenSeconds: return 15
        }
    }
    
    var creditCost: Int {
        switch self {
        case .tenSeconds: return 50
        case .fifteenSeconds: return 70
        }
    }
}

enum VideoSaverError: Error {
    case invalidURL
    case missingData
}

struct VideoSaver {
    static func saveVideo(from urlString: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let videoURL = URL(string: urlString) else {
            completion(.failure(VideoSaverError.invalidURL))
            return
        }
        
        URLSession.shared.dataTask(with: videoURL) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(VideoSaverError.missingData))
                return
            }
            
            do {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("video_\(UUID().uuidString).mp4")
                try data.write(to: tempURL)
                UISaveVideoAtPathToSavedPhotosAlbum(tempURL.path, nil, nil, nil)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - Format Button Component
struct FormatButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    if isSelected {
                        Circle()
                            .fill(Color(red: 0.35, green: 0.75, blue: 1.0))
                            .frame(width: 12, height: 12)
                            .padding(8)
                    }
                }
                
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(isSelected ? Color(red: 0.35, green: 0.75, blue: 1.0) : .white.opacity(0.5))
                
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .liquidGlass(
                cornerRadius: 18,
                tint: isSelected ? brandAccentColor : Color.white.opacity(0.25)
            )
        }
    }
}

// MARK: - Duration Button Component
struct DurationButton: View {
    let duration: String
    let credits: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                VStack(spacing: 6) {
                    Text(duration)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text(credits)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                VStack {
                    HStack {
                        Spacer()
                        if isSelected {
                            Circle()
                                .fill(Color(red: 0.35, green: 0.75, blue: 1.0))
                                .frame(width: 10, height: 10)
                                .padding(6)
                        }
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .liquidGlass(
                cornerRadius: 16,
                tint: isSelected ? brandAccentColor : Color.white.opacity(0.25)
            )
        }
    }
}

private extension View {
    func liquidGlass(cornerRadius: CGFloat = 16, tint: Color = brandAccentColor) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.black.opacity(0.25))
                    .background(materialBackground(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1.1)
                            .blendMode(.screen)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(tint.opacity(0.45), lineWidth: 1.8)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: UnitPoint(x: 0.2, y: 0.1),
                            endPoint: .bottomTrailing
                        )
                    )
                    .blur(radius: 20)
                    .opacity(0.25)
                    .blendMode(.screen)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 22, x: 0, y: 18)
            .shadow(color: tint.opacity(0.3), radius: 12, x: 0, y: 10)
    }
    
    @ViewBuilder
    private func materialBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 15.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white.opacity(0.08))
        }
    }
}

struct PrimaryButton: View {
    let label: String
    var icon: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(label)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .foregroundColor(isEnabled ? .black : Color.black.opacity(0.5))
            .background(
                (isEnabled ? Color(red: 0.35, green: 0.75, blue: 1.0) : Color(red: 0.35, green: 0.75, blue: 1.0).opacity(0.5))
            )
            .cornerRadius(12)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.7)
    }
}

struct AppleSignInButtonView: View {
    @EnvironmentObject private var userSession: UserSession
    
    var body: some View {
        SignInWithAppleButton(
            .signIn,
            onRequest: { request in
                request.requestedScopes = [.email]
            },
            onCompletion: handleCompletion
        )
        .signInWithAppleButtonStyle(.whiteOutline)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func handleCompletion(result: Result<ASAuthorization, Error>) {
        if case .success(let auth) = result,
           let credential = auth.credential as? ASAuthorizationAppleIDCredential {
            // Apple ne renvoie l'email explicite qu'une seule fois.
            // On tente de la récupérer depuis l'identity token si besoin.
            let resolvedEmail = credential.email ?? decodeEmail(from: credential.identityToken)
            userSession.handleSignIn(userID: credential.user, email: resolvedEmail)
        }
    }
    
    private func decodeEmail(from identityToken: Data?) -> String? {
        guard let tokenData = identityToken,
              let tokenString = String(data: tokenData, encoding: .utf8) else {
            return nil
        }
        
        let segments = tokenString.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        
        var payload = String(segments[1])
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = 4 * ((payload.count + 3) / 4)
        payload = payload.padding(toLength: paddingLength, withPad: "=", startingAt: 0)
        
        guard let payloadData = Data(base64Encoded: payload) else { return nil }
        
        struct IdentityPayload: Decodable {
            let email: String?
        }
        
        return (try? JSONDecoder().decode(IdentityPayload.self, from: payloadData))?.email
    }
}

struct LockedSectionView: View {
    let title: String
    let description: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0))
            
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            Text(description)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            
            AppleSignInButtonView()
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.12))
        )
        .padding(30)
    }
}

// MARK: - Subscription View
struct SubscriptionView: View {
    @EnvironmentObject private var userSession: UserSession
    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if userSession.isSignedIn {
                subscriptionContent
                    .task {
                        await storeManager.loadProducts()
                        // Forcer la vérification du statut d'abonnement à chaque ouverture
                        await storeManager.refreshSubscriptionStatus(session: userSession)
                    }
                    .onAppear {
                        // Vérifier aussi le statut quand la vue apparaît
                        Task {
                            await storeManager.refreshSubscriptionStatus(session: userSession)
                        }
                    }
            } else {
                LockedSectionView(
                    title: "Connectez-vous pour découvrir les offres",
                    description: "Vos abonnements et crédits sont liés à votre compte."
                )
            }
        }
        .alert(storeManager.purchaseMessage ?? "", isPresented: Binding(
            get: { storeManager.purchaseMessage != nil },
            set: { _ in storeManager.purchaseMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        }
    }
    
    private var subscriptionContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Choisissez l'offre qui vous convient")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.top, 20)
                
                subscriptionCard(
                    title: "Premium Hebdomadaire",
                    subtitle: "Renouvelé chaque semaine",
                    productType: .subscription,
                    benefits: [
                        "1000 crédits par semaine",
                        "Renouvellement automatique",
                        "Résiliable à tout moment"
                    ],
                    buttonLabel: "S'abonner"
                )
                
                Text("Packs de crédits")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                
                subscriptionCard(
                    title: "Pack 2000 crédits",
                    subtitle: "Ajout instantané",
                    productType: .pack2k,
                    benefits: [
                        "Nécessite un abonnement actif",
                        "Débit unique",
                        "2k crédits à utiliser"
                    ],
                    buttonLabel: "19,99 €"
                )
                
                subscriptionCard(
                    title: "Pack 5000 crédits",
                    subtitle: "Pour des campagnes plus longues",
                    productType: .pack5k,
                    benefits: [
                        "Nécessite un abonnement actif",
                        "Débit unique",
                        "5k crédits à utiliser"
                    ],
                    buttonLabel: "49,99 €"
                )
                
                subscriptionCard(
                    title: "Pack 10000 crédits",
                    subtitle: "Production intensive",
                    productType: .pack10k,
                    benefits: [
                        "Nécessite un abonnement actif",
                        "Débit unique",
                        "10k crédits à utiliser"
                    ],
                    buttonLabel: "99,99 €"
                )
                
                legalLinks
                    .padding(.top, 10)
            }
            .padding(20)
        }
    }
    
    private func subscriptionCard(title: String, subtitle: String, productType: StoreManager.ProductType, benefits: [String], buttonLabel: String) -> some View {
        let product = storeManager.product(for: productType)
        let isSubscriptionCard = productType == .subscription
        let subscriptionActive = userSession.hasActiveSubscription
        let finalLabel: String
        let isEnabled: Bool
        
        if isSubscriptionCard {
            finalLabel = subscriptionActive ? "Abonné ✅" : "S'abonner"
            isEnabled = !subscriptionActive
        } else {
            finalLabel = buttonLabel
            isEnabled = subscriptionActive
        }
        
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                Spacer()
                Text(product?.displayPrice ?? placeholderPrice(for: productType))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(benefits, id: \.self) { benefit in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0))
                        Text(benefit)
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                    }
                }
            }
            
            PrimaryButton(label: finalLabel, icon: "sparkles", isEnabled: isEnabled) {
                guard isEnabled else { return }
                Task {
                    await storeManager.purchase(productType, session: userSession)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.12))
        )
    }
    
    private func placeholderPrice(for type: StoreManager.ProductType) -> String {
        switch type {
        case .subscription:
            return "9,99 € / semaine"
        case .pack2k:
            return "19,99 €"
        case .pack5k:
            return "49,99 €"
        case .pack10k:
            return "99,99 €"
        }
    }
    
    private var legalLinks: some View {
        VStack(spacing: 12) {
            Button(action: {
                if let url = URL(string: "https://www.world-creat.com/politique-confidentialite") {
                    openURL(url)
                }
            }) {
                Text("Politique de confidentialité")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(brandAccentColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(brandAccentColor.opacity(0.6), lineWidth: 1)
                    )
            }
            
            Button(action: {
                if let url = URL(string: "https://www.world-creat.com/cgu") {
                    openURL(url)
                }
            }) {
                Text("CGU")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(brandAccentColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(brandAccentColor.opacity(0.6), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Profile View
struct ProfileView: View {
    @EnvironmentObject private var userSession: UserSession
    @EnvironmentObject private var generationStore: GenerationStore
    @State private var showDeleteAlert = false
    @State private var downloadMessage = ""
    @State private var showDownloadAlert = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if userSession.isSignedIn {
                    profileHeader
                } else {
                    signInCard
                }
                
                historySection
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .alert(downloadMessage, isPresented: $showDownloadAlert) {
            Button("OK", role: .cancel) { }
        }
        .alert("Supprimer votre compte ?", isPresented: $showDeleteAlert) {
            Button("Annuler", role: .cancel) { }
            Button("Supprimer", role: .destructive) {
                userSession.signOut()
                generationStore.clear()
            }
        } message: {
            Text("Cette action effacera votre historique de génération.")
        }
    }
    
    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Circle()
                    .fill(Color(red: 0.1, green: 0.5, blue: 0.9))
                    .frame(width: 70, height: 70)
                    .overlay(
                        Text(userSession.initials)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    )
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connecté en tant que")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                    Text(userSession.email)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text("\(userSession.credits) crédits")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.35, green: 0.75, blue: 1.0))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            
            PrimaryButton(label: "Se déconnecter", icon: "arrowshape.turn.up.left") {
                userSession.signOut()
                generationStore.clear()
            }
            
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Supprimer mon compte")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.6), lineWidth: 1)
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color(red: 0.1, green: 0.3, blue: 0.5), lineWidth: 1)
                )
        )
    }
    
    private var signInCard: some View {
        VStack(spacing: 20) {
            Text("Connectez-vous pour retrouver vos crédits et vos vidéos.")
                .font(.system(size: 16))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            AppleSignInButtonView()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.1))
        )
    }
    
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dernière vidéo générée")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            
            if !userSession.isSignedIn {
                placeholderCard(text: "Connectez-vous pour consulter votre dernière vidéo.")
            } else if generationStore.history.isEmpty {
                placeholderCard(text: "Aucune vidéo générée pour le moment")
            } else {
                if let latest = generationStore.history.first {
                    historyCard(for: latest)
                }
            }
        }
    }
    
    private func placeholderCard(text: String) -> some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(red: 0.08, green: 0.08, blue: 0.12))
            .frame(height: 160)
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.4))
                    Text(text)
                        .foregroundColor(.white.opacity(0.6))
                }
            )
    }
    
    private func historyCard(for item: GeneratedVideo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = URL(string: item.url) {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 180)
                    .cornerRadius(12)
            }
            
            Text(item.prompt.isEmpty ? "Prompt non renseigné" : item.prompt)
                .font(.system(size: 14))
                .foregroundColor(.white)
            
            HStack {
                Label(item.format == .landscape ? "Paysage" : "Portrait", systemImage: "aspectratio")
                Spacer()
                Label("\(item.duration.secondsValue)s", systemImage: "clock")
                Spacer()
                Text(item.date, style: .date)
            }
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.7))
            
            PrimaryButton(label: "Télécharger", icon: "arrow.down.circle.fill") {
                VideoSaver.saveVideo(from: item.url) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            downloadMessage = "Vidéo téléchargée dans votre galerie."
                        case .failure:
                            downloadMessage = "Impossible de télécharger la vidéo."
                        }
                        showDownloadAlert = true
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.12))
        )
    }
    
    private func dismissKeyboard() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }
}

#Preview("MainTabView") {
    MainTabView()
}

#Preview("ContentView") {
    ContentView()
}



