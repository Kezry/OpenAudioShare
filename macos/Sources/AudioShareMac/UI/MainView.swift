import AppKit
import AudioShareCore
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    private var theme: FluentTheme { FluentTheme(colorScheme: colorScheme) }

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(width: 500, height: 463)
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text(L10n.t("ok"))))
        }
        .alert(L10n.t("permissionTitle"), isPresented: $model.showPermissionGuide) {
            Button(L10n.t("openSettings")) { model.openPermissionSettings() }
            Button(L10n.t("later"), role: .cancel) { model.dismissPermissionGuide() }
        } message: {
            Text(L10n.t("permissionMessage"))
        }
        .alert(L10n.t("addIPTitle"), isPresented: $model.isAddIPPresented) {
            TextField("192.168.1.20:8088", text: $model.addIPText)
            Button(L10n.t("cancel"), role: .cancel) {}
            Button(L10n.t("ok")) { model.addIP() }
        } message: {
            Text(L10n.t("addIPPrompt"))
        }
    }

    private var background: some View {
        ZStack {
            if model.acrylic {
                VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
                theme.windowGradient.opacity(colorScheme == .dark ? 0.78 : 0.70)
            } else {
                theme.windowGradient
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            topRow
                .padding(.top, 4)
            SectionLabel(text: L10n.t("audioDeviceSelection"), theme: theme)
                .padding(.top, 2)
            audioRow
            captureRow
                .padding(.top, 3)
            SectionLabel(text: L10n.t("channelMode"), theme: theme)
                .padding(.top, 2)
            channelRow
            playbackHeader
                .padding(.top, 3)
            deviceList
                .padding(.top, 3)
            if model.addIPVisible {
                searchRow
                    .padding(.top, 3)
            }
            volumeRow
                .padding(.top, 4)
            gainRow
                .padding(.top, 3)
            actionRow
                .padding(.top, 4)
            Spacer(minLength: 0)
            FluentButton(title: L10n.t("exit"), color: theme.danger, theme: theme,
                         width: 400, height: 30, action: { NSApp.terminate(nil) })
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 50)
        .frame(width: 500, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var topRow: some View {
        HStack(spacing: 0) {
            Text(L10n.t("startup"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
            FluentToggle(isOn: Binding(get: { model.startupEnabled },
                                       set: { model.setStartup($0) }),
                         theme: theme)
                .padding(.leading, 5)
            Text(L10n.t("autoConnect"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .padding(.leading, 10)
            FluentToggle(isOn: Binding(get: { model.autoConnect },
                                       set: { model.setAutoConnect($0) }),
                         theme: theme)
                .padding(.leading, 5)
            Spacer(minLength: 4)
            Circle()
                .fill(model.connected ? theme.success : theme.danger)
                .frame(width: 8, height: 8)
            Text(model.connectedLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .padding(.leading, 4)
        }
        .frame(width: 400, height: 20)
    }

    private var audioRow: some View {
        HStack(spacing: 10) {
            FluentComboBox(
                items: model.audioDevices.map(\.id),
                selection: Binding(get: { model.selectedAudioUID },
                                   set: { model.selectAudioDevice($0) }),
                label: { uid in
                    model.audioDevices.first(where: { $0.id == uid })?.name ?? ""
                },
                theme: theme,
                width: 210,
                enabled: model.audioControlsEnabled
            )
            FluentComboBox(
                items: sampleRates,
                selection: Binding(get: { model.sampleRate },
                                   set: { model.selectSampleRate($0) }),
                label: { sampleRateLabel($0) },
                theme: theme,
                width: 80,
                enabled: model.audioControlsEnabled
            )
            FluentButton(title: L10n.t("refresh"), color: theme.info, theme: theme,
                         width: 90, enabled: model.audioControlsEnabled,
                         action: { model.refreshAudioDevices() })
        }
        .frame(width: 400)
    }

    private var captureRow: some View {
        HStack(spacing: 5) {
            Text(L10n.t("captureMode"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize()
            FluentComboBox(
                items: CaptureMode.allCases,
                selection: Binding(get: { model.captureMode },
                                   set: { model.setCaptureMode($0) }),
                label: { L10n.captureModeName($0) },
                theme: theme,
                width: 138
            )
            Text(L10n.t("captureProfile"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize()
                .padding(.leading, 3)
            FluentComboBox(
                items: CaptureProfile.allCases,
                selection: Binding(get: { model.captureProfile },
                                   set: { model.setCaptureProfile($0) }),
                label: { L10n.profileName($0) },
                theme: theme,
                width: 160
            )
        }
        .frame(width: 400)
    }

    private var channelRow: some View {
        HStack(spacing: 8) {
            FluentComboBox(
                items: ChannelMode.allCases,
                selection: Binding(get: { model.channelMode },
                                   set: { model.setChannelMode($0) }),
                label: { L10n.modeName($0) },
                theme: theme,
                width: 130
            )
            Text(model.captureHint)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 400)
    }

    private var playbackHeader: some View {
        HStack(spacing: 0) {
            Text(L10n.t("audioPlaybackDevice"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text("USB")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            FluentToggle(isOn: Binding(get: { model.isUSB },
                                       set: { model.setUSB($0) }),
                         theme: theme)
                .padding(.leading, 5)
            if model.isUSB {
                ZStack {
                    FluentButton(title: L10n.t("refresh"), color: theme.info, theme: theme,
                                 width: 70, height: 28,
                                 enabled: !model.adbLoading,
                                 action: { model.refreshSpeakers() })
                    if model.adbLoading {
                        SmallSpinner()
                    }
                }
                .padding(.leading, 8)
            }
        }
        .frame(width: 400, height: 28)
    }

    private var deviceList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 5) {
                if model.speakers.isEmpty {
                    HStack {
                        Text(model.isUSB ? L10n.t("waitingUSB") : L10n.t("emptyIP"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                    .frame(height: 32)
                    .padding(.horizontal, 10)
                }
                ForEach(model.speakers) { speaker in
                    SpeakerRow(speaker: speaker, model: model, theme: theme)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 400, height: deviceListHeight)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.listBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(theme.fieldBorder, lineWidth: 1)
        )
        .clipped()
    }

    private var deviceListHeight: CGFloat {
        96
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            FluentButton(title: L10n.t("searchSpeaker"), color: theme.info, theme: theme,
                         width: 195, action: { model.searchSpeakers() })
            FluentButton(title: L10n.t("add"), color: theme.info, theme: theme,
                         width: 195, action: {
                             model.addIPText = ""
                             model.isAddIPPresented = true
                         })
        }
        .frame(width: 400)
    }

    private var volumeRow: some View {
        HStack(spacing: 0) {
            Text(L10n.t("volume"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Text("\(model.volume)")
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 30)
            FluentSlider(value: Binding(get: { Double(model.volume) },
                                        set: { model.setVolume(Int($0.rounded())) }),
                         theme: theme, range: 0...100, width: 212,
                         enabled: !model.followSystemVolume)
            Text(L10n.t("followSystem"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 7)
            FluentToggle(isOn: Binding(get: { model.followSystemVolume },
                                       set: { model.setFollowSystemVolume($0) }),
                         theme: theme)
                .padding(.leading, 4)
        }
        .frame(width: 400, height: 20)
    }

    private var gainRow: some View {
        HStack(spacing: 0) {
            Text(L10n.t("gain"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Text("\(model.gain)%")
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 42)
            FluentSlider(value: Binding(get: { Double(model.gain) },
                                        set: { model.setGain(Int($0.rounded())) }),
                         theme: theme, range: 25...400, width: 188)
            Text(L10n.t("autoGain"))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 8)
                .help(L10n.t("autoGainTip"))
            FluentToggle(isOn: Binding(get: { model.autoGain },
                                       set: { model.setAutoGain($0) }),
                         theme: theme)
                .padding(.leading, 4)
                .help(L10n.t("autoGainTip"))
        }
        .frame(width: 400, height: 20)
    }

    private var actionRow: some View {
        HStack(spacing: 5) {
            FluentButton(title: L10n.t("connectAll"), color: theme.success, theme: theme,
                         width: 125, action: { model.connectAll() })
            FluentButton(title: L10n.t("disconnectAll"), color: theme.caution, theme: theme,
                         width: 125, action: { model.disconnectAll() })
            FluentButton(title: L10n.t("syncDevices"), color: theme.info, theme: theme,
                         width: 140, action: { model.syncDevices(applyNow: true) })
        }
        .frame(width: 400)
    }

    private var sampleRates: [Int] {
        [192_000, 176_400, 96_000, 48_000, 44_100, 16_000, 8_000]
    }

    private func sampleRateLabel(_ rate: Int) -> String {
        switch rate {
        case 44_100: return "44.1kHz"
        case 176_400: return "176.4kHz"
        default: return "\(rate / 1_000)kHz"
        }
    }
}

private struct CloseButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovered ? Color.red.opacity(configuration.isPressed ? 0.9 : 0.75) : Color.clear)
            )
            .foregroundStyle(hovered ? Color.white : Color.secondary)
            .onHover { hovered = $0 }
    }
}

private struct SpeakerRow: View {
    @ObservedObject var speaker: Speaker
    @ObservedObject var model: AppModel
    let theme: FluentTheme

    private var channelOptions: [AudioChannel] {
        var channels = model.channelOptions
        if !channels.contains(speaker.channel) { channels.append(speaker.channel) }
        return channels
    }

    var body: some View {
        HStack(spacing: 5) {
            FluentTextField(
                text: Binding(get: { speaker.display },
                              set: { speaker.display = $0 }),
                theme: theme,
                enabled: !speaker.idReadOnly,
                readOnly: speaker.idReadOnly,
                onSubmit: { model.renameSpeaker(speaker, newValue: speaker.display) }
            )
            .frame(minWidth: 80, maxWidth: .infinity)

            FluentComboBox(
                items: channelOptions,
                selection: Binding(get: { speaker.channel },
                                   set: { model.setSpeakerChannel(speaker, channel: $0) }),
                label: { L10n.channelName($0) },
                theme: theme,
                width: 82,
                enabled: speaker.channelEnabled
            )

            if speaker.connected {
                HStack(spacing: 2) {
                    Circle()
                        .fill(qualityColor)
                        .frame(width: 7, height: 7)
                    Text(speaker.lastRTT > 0 ? "\(speaker.lastRTT)ms" : "--")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 26, alignment: .leading)
                }
                .frame(width: 38)
            }

            if speaker.removeVisible && speaker.status == .disconnected {
                Button {
                    model.removeSpeaker(speaker)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 18, height: 30)
                }
                .buttonStyle(.plain)
                .help(L10n.t("remove"))
            }

            if speaker.status == .connecting {
                FluentButton(title: "…", color: theme.buttonDisabled, theme: theme,
                             width: 80, enabled: false, action: {})
            } else if speaker.connected {
                FluentButton(title: L10n.t("disconnecte"), color: theme.caution, theme: theme,
                             width: 80, action: { model.disconnectSpeaker(speaker) })
            } else {
                FluentButton(title: L10n.t("connecte"), color: theme.info, theme: theme,
                             width: 80, enabled: speaker.connectEnabled,
                             action: { model.connectSpeaker(speaker) })
            }
        }
        .frame(width: 400)
        .padding(.horizontal, 6)
    }

    private var qualityColor: Color {
        if speaker.lastRTT <= 0 { return theme.textDisabled }
        if speaker.lastRTT <= 20 { return theme.success }
        if speaker.lastRTT <= 50 { return theme.caution }
        return theme.danger
    }
}
