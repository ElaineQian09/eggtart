# Broadcast Upload Extension Setup

1. In Xcode, add target: `File > New > Target > Broadcast Upload Extension`.
2. Extension target bundle id should match app-side setting:
`luciayuanzhu.eggtart.BroadcastUpload`.
3. Enable `App Groups` capability for both app target and extension target.
4. Use the same App Group id in both targets:
`group.eggtart.screenrecord`.
5. Replace extension `SampleHandler.swift` with `BroadcastUploadTemplate/SampleHandler.swift`.
6. In app code, record button triggers `RPSystemBroadcastPickerView`.
7. Start flow:
tap record in app -> system picker -> choose `Eggtart` -> leave app -> record on Home Screen.
8. Stop flow:
tap record in app again (opens picker) or stop from system recording UI.
9. Extension writes status/files into App Group container.
10. App detects completion and uploads `audio_url` + `screen_recording_url` to backend event.

