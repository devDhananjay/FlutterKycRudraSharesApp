import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/services/connectivity_controller.dart';
import 'package:meon_kyc/services/storage_service.dart';
import 'package:meon_kyc/app.dart';
import 'package:meon_kyc/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StorageService.resetOnFreshInstall();
  print("hastoken : ${await StorageService.hasAccessToken()}");
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  final connectivityController = ConnectivityController();
  await connectivityController.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStore()),
        ChangeNotifierProvider<ConnectivityController>.value(
          value: connectivityController,
        ),
      ],
      child: const MeonKycApp(),
    ),
  );
}
