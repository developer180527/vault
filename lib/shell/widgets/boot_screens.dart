import 'package:flutter/material.dart';

/// Shown while the capability manifest is being fetched from the server. The
/// shell can't render until we know what this device+profile is allowed to see.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 28, height: 28, child: CircularProgressIndicator()),
            SizedBox(height: 16),
            Text('Connecting to your Vault…'),
          ],
        ),
      ),
    );
  }
}
