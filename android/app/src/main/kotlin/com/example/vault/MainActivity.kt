package com.example.vault

import com.ryanheise.audioservice.AudioServiceFragmentActivity

// Extends the audio_service activity so just_audio_background can run the
// media foreground service and show lock-screen controls. The Fragment
// variant (a FlutterFragmentActivity) is required by local_auth's biometric
// prompt — same audio behavior otherwise.
class MainActivity : AudioServiceFragmentActivity()
