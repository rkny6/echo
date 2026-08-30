import SwiftUI

/// The message input bar (text field, send button, image attach).
///
/// This used to live directly inside `ChatScreen`, with `input` as `@State`
/// on `ChatScreen` itself. Because a SwiftUI view's entire `body` re-runs
/// whenever any of its own `@State` changes, every keystroke was re-running
/// `ChatScreen.body` — which re-grouped and re-sorted the *entire* chat
/// history and rebuilt every message bubble, even though none of that had
/// changed. That's the main cause of the typing lag.
///
/// By owning `input` (and the other composer-only state) in its own view,
/// a keystroke here only re-renders `ChatComposerView`, not the message
/// list above it.
struct ChatComposerView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) var colorScheme

    @State private var input = ""
    @State private var showImagePicker = false
    @State private var showImageSendHint = false
    @State private var selectedImage: UIImage?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showImageSendHint {
                HStack {
                    Text("请在设置中启用图片发送并配置 Agnes API。")
                        .font(.footnote)
                        .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            Divider()
                .background(AppTheme.dividerColor(colorScheme))

            if let selectedUIImage = selectedImage {
                HStack(alignment: .top, spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: selectedUIImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipped()
                            .cornerRadius(12)

                        Button(action: {
                            withAnimation(.easeInOut) {
                                selectedImage = nil
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AppTheme.tertiaryTextColor(colorScheme))
                                .background(
                                    Circle()
                                        .fill(AppTheme.surfaceColor(colorScheme))
                                )
                        }
                        .offset(x: 6, y: -6)
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("已选择图片，可继续输入文字作为说明")
                            .font(.footnote)
                            .foregroundColor(AppTheme.textColor(colorScheme))
                        Text("发送后，图片和文字将一起提交")
                            .font(.caption2)
                            .foregroundColor(AppTheme.tertiaryTextColor(colorScheme))
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)      // 下移
                .padding(.bottom, 2)    // 补偿
            }

            HStack(alignment: .bottom, spacing: 12) {
                Button(action: {
                    if viewModel.appSettings.allowImageSending {
                        showImagePicker = true
                    } else if FeatureFlags.enableImageSendRestrictionHint {
                        withAnimation(.easeInOut) { showImageSendHint = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation(.easeInOut) { showImageSendHint = false }
                        }
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(viewModel.appSettings.allowImageSending ? AppTheme.adaptiveAccentColor(colorScheme) : AppTheme.tertiaryTextColor(colorScheme))
                        .frame(width: 44, height: 44)
                        .background(AppTheme.surfaceColor(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(viewModel.appSettings.allowImageSending ? 1.0 : 0.40)
                }
                .buttonStyle(.plain)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundStyle(AppTheme.textColor(colorScheme))
                        .frame(minHeight: 20, alignment: .topLeading)
                            .padding(.vertical, 7)
                        .focused($isInputFocused)
                        .accessibilityLabel("消息")
                        .onChange(of: input) { newValue in
                            viewModel.userInputDidChange(newValue)
                        }

                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(AppTheme.adaptiveAccentColor(colorScheme))
                            )
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedImage == nil)
                    .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedImage == nil ? 0.35 : 1.0)
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(AppTheme.surfaceColor(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(AppTheme.inputFieldBorderColor(colorScheme), lineWidth: 1)
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(AppTheme.chatBackgroundColor(colorScheme))
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(selectedImage: $selectedImage)
        }
    }

    private func sendMessage() {
        let message = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !message.isEmpty
        let hasImage = selectedImage != nil

        guard hasText || hasImage else { return }

        if let image = selectedImage {
            let content = hasText ? message : "发送了一张图片"
            let imageData = image.jpegData(compressionQuality: 0.85) ?? image.pngData()
            guard let imageData else { return }

            Task {
                await viewModel.sendUserImageMessage(content: content, imageData: imageData)
            }
            selectedImage = nil
        } else {
            Task {
                await viewModel.sendUserMessage(message)
            }
        }

        input = ""
        viewModel.userInputDidChange("")
        // Keep the keyboard up after send so the transcript does not fight a
        // simultaneous keyboard-hide + content-size animation. Users can still
        // dismiss with the scroll gesture or by tapping the message list.
    }
}

#Preview {
    ChatComposerView(viewModel: PreviewFactory.appViewModel())
}
