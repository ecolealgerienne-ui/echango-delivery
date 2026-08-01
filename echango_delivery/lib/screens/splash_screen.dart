import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/common_strings.dart';
import '../state/locale_state.dart';
import '../theme/app_spacing.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.local_shipping,
              size: 80,
              color: Theme.of(context).primaryColor,
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Echango Delivery',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              commonLabel('common.splash.tagline',
                  context.read<LocaleState>().locale),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xxl),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
