import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:meon_kyc/config/env_config.dart';

class PopupModal extends StatelessWidget {
  final Map<String, dynamic> popupData;
  final VoidCallback onClose;
  final void Function(String) onSelect;
  final String fieldName;

  const PopupModal({
    super.key,
    required this.popupData,
    required this.onClose,
    required this.onSelect,
    required this.fieldName,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClose,
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: GestureDetector(
          onTap: () {},
          child: Container(
            margin: const EdgeInsets.all(16),
            constraints: const BoxConstraints(maxWidth: 600, maxHeight: 500),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade800,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        fieldName == 'view_equity_plan'
                            ? 'Select Brokerage Plan'
                            : 'Tariff Sheet',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: fieldName == 'view_equity_plan'
                        ? _buildBrokerageContent(context)
                        : fieldName == 'tarrif_sheet'
                            ? _buildPdfContent(context)
                            : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrokerageContent(BuildContext context) {
    final plans = [
      ['Equity Intraday', 'Flat Rs 20 or 0.03% (whichever is lower) per executed order'],
      ['Equity Delivery', 'Flat Rs 20 or 0.30% (whichever is lower) per executed order'],
      ['Currency Option', 'Flat Rs 20 or 0.03% (whichever is lower) per executed order'],
      ['Equity Options', 'Flat Rs 20 per executed order (on Turnover)'],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Without RM (After 30th June)',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        ...plans.map((p) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(p[0], style: const TextStyle(fontWeight: FontWeight.w500)),
                    Expanded(
                      child: Text(
                        p[1],
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            )),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () {
            onSelect('BROKERAGE MODULE');
            onClose();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue.shade600,
            foregroundColor: Colors.white,
          ),
          child: const Text('Select This Plan'),
        ),
      ],
    );
  }

  Widget _buildPdfContent(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 400,
          child: InAppWebView(
            url:
                '${EnvConfig.baseUrl}/static/static_upload_files/kediacapital/Tariff%20Plan.pdf',
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: onClose,
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class InAppWebView extends StatelessWidget {
  final String url;

  const InAppWebView({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => launchUrl(Uri.parse(url)),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.picture_as_pdf, size: 64, color: Colors.red.shade400),
            const SizedBox(height: 8),
            const Text('Tap to open PDF in browser'),
          ],
        ),
      ),
    );
  }
}
