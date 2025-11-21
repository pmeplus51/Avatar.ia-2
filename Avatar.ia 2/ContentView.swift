//
//  ContentView.swift
//  Avatar.ia 2
//
//  Created by Théophile toulemonde on 21/11/2025.
//

import SwiftUI

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
                    
                    // Points de pagination
                    paginationDots
                        .padding(.bottom, 30)
                    
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
        HStack(spacing: 15) {
            // Panneau Avant
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white)
                        .frame(height: 200)
                    
                    // Image avant - Veste bleue sur fond blanc
                    VStack {
                        // Logo CRAFT en haut à gauche
                        HStack {
                            Text("CRAFT")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.leading, 12)
                                .padding(.top, 12)
                            Spacer()
                        }
                        
                        Spacer()
                        
                        // Représentation de la veste bleue
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.2, green: 0.5, blue: 0.9))
                                .frame(width: 100, height: 120)
                            
                            // Détails de la veste (fermeture, capuche)
                            VStack(spacing: 4) {
                                // Capuche
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(red: 0.15, green: 0.45, blue: 0.85))
                                    .frame(width: 60, height: 20)
                                
                                // Corps de la veste
                                Rectangle()
                                    .fill(Color(red: 0.2, green: 0.5, blue: 0.9))
                                    .frame(width: 80, height: 80)
                                
                                // Ligne de fermeture
                                Rectangle()
                                    .fill(Color(red: 0.1, green: 0.4, blue: 0.8))
                                    .frame(width: 3, height: 60)
                            }
                        }
                        
                        Spacer()
                    }
                }
                
                Text("Avant")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            
            // Panneau Après
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.4, blue: 0.25),
                                    Color(red: 0.2, green: 0.5, blue: 0.3),
                                    Color(red: 0.25, green: 0.55, blue: 0.35)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 200)
                    
                    // Overlay avec bouton play au centre
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 60, height: 60)
                        
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .offset(x: 2)
                    }
                }
                
                Text("Après")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
        }
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
    }
    
    // MARK: - Description Section
    private var descriptionSection: some View {
        Text("Créez des vidéos ultra-réalistes de vos produits avec une simple photo et un prompt")
            .font(.system(size: 16))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
    }
    
    // MARK: - Action Buttons
    private var actionButtons: some View {
        HStack(spacing: 15) {
            ActionButton(
                customIcon: AnyView(ImportIcon()),
                label: "Importez"
            )
            
            ActionButton(
                icon: "sparkles",
                label: "Décrivez"
            )
            
            ActionButton(
                icon: "video.fill",
                label: "Générez"
            )
            
            ActionButton(
                icon: "rocket.fill",
                label: "Déployez"
            )
        }
    }
}

// MARK: - Action Button Component
struct ActionButton: View {
    var icon: String? = nil
    var customIcon: AnyView? = nil
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
                    
                    if let customIcon = customIcon {
                        customIcon
                    } else if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                }
                
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Import Icon (Carré avec flèche vers le haut et ligne en bas)
struct ImportIcon: View {
    var body: some View {
        ZStack {
            // Carré
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 32, height: 32)
            
            VStack(spacing: 4) {
                // Flèche vers le haut
                VStack(spacing: 0) {
                    // Pointe de flèche
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: -4, y: 4))
                        path.addLine(to: CGPoint(x: 4, y: 4))
                        path.closeSubpath()
                    }
                    .fill(Color.white)
                    .frame(width: 8, height: 4)
                    
                    // Ligne verticale
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1.5, height: 6)
                }
                
                // Ligne horizontale en bas
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 12, height: 1.5)
            }
        }
    }
}

#Preview {
    ContentView()
}
