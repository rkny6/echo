import SwiftUI

// MARK: - Keyboard Helpers

/// Resigns first responder via the UIKit responder chain. Safe to call from
/// any view regardless of which view owns the SwiftUI `@FocusState`.
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Screen Background Container
struct ScreenBackground<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            LinearGradient.screenBackgroundGradient(colorScheme)
                .ignoresSafeArea()
            Color.clear
            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Modern Card Component
struct ModernCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surfaceColor(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderColor(colorScheme), lineWidth: 1)
        )
        .shadow(
            color: AppTheme.cardShadowColor(colorScheme),
            radius: 8,
            x: 0,
            y: 3
        )
    }
}

// MARK: - Settings Card Container
struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let content: () -> Content

    init(title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        ModernCard {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .foregroundColor(AppTheme.textColor(colorScheme))
                    
                    Text(subtitle)
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                        .opacity(0.80)
                }
                
                VStack(spacing: 16) {
                    content()
                }
            }
        }
    }
}

// MARK: - Profile Text Field
struct ProfileTextField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .textCase(.none)
            
            TextField(placeholder, text: $text)
                .font(.system(size: 16, weight: .regular, design: .default))
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.inputFieldBackground(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                )
        }
    }
}

// MARK: - Profile Text Editor
struct ProfileTextEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let prompt: String
    @Binding var text: String
    let minHeight: CGFloat

    init(title: String, prompt: String, text: Binding<String>, minHeight: CGFloat = 140) {
        self.title = title
        self.prompt = prompt
        self._text = text
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                .textCase(.none)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .opacity(0.70)
                }

                TextEditor(text: $text)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundColor(AppTheme.textColor(colorScheme))
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.inputFieldBackground(colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                    )
                    .frame(minHeight: minHeight)
            }
        }
    }
}

// MARK: - Primary Action Button
struct PrimaryButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.adaptiveAccentColor(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            Color.white.opacity(disabled ? 0 : 0.15),
                            lineWidth: 1
                        )
                )
        }
        .opacity(disabled ? 0.60 : 1.0)
        .disabled(disabled)
    }
}

// MARK: - Secondary Action Button
struct SecondaryButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.adaptiveAccentColor(colorScheme), lineWidth: 2)
                )
        }
        .opacity(disabled ? 0.60 : 1.0)
        .disabled(disabled)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light, design: .default))
                .foregroundColor(AppTheme.secondaryTextColor(colorScheme).opacity(0.60))
                .padding(.bottom, 8)

            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.textColor(colorScheme))

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundColor(AppTheme.secondaryTextColor(colorScheme))
                    .multilineTextAlignment(.center)
                    .opacity(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }
}

// MARK: - Divider Extension
struct MinimalDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Divider()
            .background(AppTheme.dividerColor(colorScheme))
    }
}

// MARK: - Avatar View Component
struct AvatarView: View {
    @Environment(\.colorScheme) private var colorScheme
    let avatarName: String
    let isUser: Bool
    let size: CGFloat
    
    init(avatarName: String, isUser: Bool, size: CGFloat = 40) {
        self.avatarName = avatarName
        self.isUser = isUser
        self.size = size
    }
    
    var body: some View {
        let avatar = AvatarManager.shared.avatarImage(filename: avatarName, isUser: isUser)

        avatar
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(AppTheme.borderColor(colorScheme), lineWidth: 1)
            )
            .foregroundColor(isUser ? AppTheme.adaptiveAccentColor(colorScheme) : AppTheme.secondaryTextColor(colorScheme))
    }
}

// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.editedImage] as? UIImage {
                parent.selectedImage = image
            } else if let image = info[.originalImage] as? UIImage {
                    parent.selectedImage = image
                }
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Avatar Picker Component
struct AvatarPicker: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var avatarName: String
    let isUser: Bool
    let onAvatarChanged: (String) -> Void
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    
    var body: some View {
        VStack(spacing: 16) {
            Button(action: {
                showImagePicker = true
            }) {
                ZStack {
                    AvatarView(avatarName: avatarName, isUser: isUser, size: 80)
                    
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "camera.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(AppTheme.adaptiveAccentColor(colorScheme))
                                .clipShape(Circle())
                                .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                        }
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Text("点击更换头像")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(selectedImage: $selectedImage)
        }
        .onChange(of: selectedImage) { _, newImage in
            if let image = newImage {
                let identifier = isUser ? "user" : "character"
                let oldFilename = AvatarManager.shared.saveAvatar(image, identifier: identifier)
                if avatarName != (isUser ? "user_default" : "character_default") {
                    AvatarManager.shared.deleteAvatar(filename: avatarName)
                }
                onAvatarChanged(oldFilename)
            }
        }
    }
}

// MARK: - View Extensions
extension View {
    func dismissKeyboardOnTap() -> some View {
        self.onTapGesture {
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        }
    }

    func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}
