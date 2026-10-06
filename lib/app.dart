import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:meon_kyc/components/app_connectivity_gate.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/pages/home_page.dart';
import 'package:meon_kyc/pages/kyc_completed_page.dart';
import 'package:meon_kyc/pages/page_not_found.dart';
import 'package:meon_kyc/pages/webview_page.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

class MeonKycApp extends StatelessWidget {
  const MeonKycApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Meon KYC',
      debugShowCheckedModeBanner: false,
      theme: KycTheme.theme,
      builder: (context, child) {
        return AppConnectivityGate(child: child ?? const SizedBox.shrink());
      },
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', 'US'),
        Locale('en', 'IN'),
        Locale('en', 'GB'),
      ],
      routerConfig: GoRouter(
        initialLocation: '/${EnvConfig.companyName}/${EnvConfig.workflowName}',
        routes: [
          GoRoute(
            path: '/:company/:workflowName',
            builder: (context, state) {
              final company = state.pathParameters['company'] ?? '';
              final workflow = state.pathParameters['workflowName'] ?? '';
              if (company.isEmpty || workflow.isEmpty) {
                return const PageNotFound();
              }
              // Pass query params from redirect URL to HomePage
              final queryParams = state.uri.queryParameters;
              return HomePage(
                company: company,
                workflowName: workflow,
                queryParams: queryParams,
              );
            },
          ),
          GoRoute(
            path: '/:company/:workflowName/webview',
            pageBuilder: (context, state) {
              final company = state.pathParameters['company'] ?? '';
              final workflow = state.pathParameters['workflowName'] ?? '';
              final url = state.uri.queryParameters['url'] ?? '';
              final title = state.uri.queryParameters['title'] ?? 'External Verification';
              if (company.isEmpty || workflow.isEmpty || url.isEmpty) {
                return const NoTransitionPage(child: PageNotFound());
              }
              return CustomTransitionPage(
                key: state.pageKey,
                child: WebViewPage(
                  url: url,
                  title: title,
                  company: company,
                  workflowName: workflow,
                ),
                transitionDuration: const Duration(milliseconds: 200),
                reverseTransitionDuration: const Duration(milliseconds: 150),
                transitionsBuilder: (context, animation, _, child) =>
                    FadeTransition(opacity: animation, child: child),
              );
            },
          ),
          GoRoute(
            path: '/:company/:workflowName/completed',
            builder: (context, state) {
              final company = state.pathParameters['company'] ?? EnvConfig.companyName;
              final workflowName = state.pathParameters['workflowName'] ?? EnvConfig.workflowName;
              return KycCompletedPage(company: company, workflowName: workflowName);
            },
          ),
          GoRoute(
            path: '/404',
            builder: (context, state) => const PageNotFound(),
          ),
        ],
        errorBuilder: (context, state) => const PageNotFound(),
        redirect: (context, state) {
          final path = state.uri.path;
          if (path == '/' || path.isEmpty) {
            return '/${EnvConfig.companyName}/${EnvConfig.workflowName}';
          }
          return null;
        },
      ),
    );
  }
}
