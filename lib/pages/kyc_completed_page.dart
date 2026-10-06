import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/components/kyc_stepper_bar.dart';
import 'package:meon_kyc/services/storage_service.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

class KycCompletedPage extends StatefulWidget {
  final String company;
  final String workflowName;

  const KycCompletedPage({
    super.key,
    required this.company,
    required this.workflowName,
  });

  @override
  State<KycCompletedPage> createState() => _KycCompletedPageState();
}

class _KycCompletedPageState extends State<KycCompletedPage> {
  String? _company;
  String? _workflowId;
  String? _currentPosition; // Position is a string like "mobile"

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadStepperData();
    });
  }

  void _loadStepperData() {
    final store = context.read<AppStore>();
    final userDetails = store.userDetails;
    
    // Extract workflowId from design_template in fieldsWithAuth (same as home_page)
    final fieldsWithAuth = store.fieldsWithAuth;
    if (fieldsWithAuth is Map) {
      final contextData = fieldsWithAuth['context'] as Map<String, dynamic>?;
      final designTemplate = contextData?['design_template']?.toString();
      if (designTemplate != null && designTemplate.contains('-')) {
        final parts = designTemplate.split('-');
        if (parts.length >= 2) {
          _workflowId = parts[1]; // Second part is workflowId
          debugPrint('[KycCompletedPage] Extracted workflowId from design_template: $_workflowId');
        }
      }
      
      // Get position (already stored in AppStore, but keep for reference)
      _currentPosition = store.currentPosition;
    }
    
    // Fallback: try user details if workflowId not found
    if ((_workflowId == null || _workflowId!.isEmpty) && userDetails is Map) {
      final data = userDetails['data'] as Map<String, dynamic>?;
      _workflowId = data?['workflow_id']?.toString() ?? 
                   data?['id']?.toString() ?? 
                   userDetails['workflow_id']?.toString();
    }
    
    // Get company and workflowName from store
    _company = store.company ?? 'mandotsecurities';
    final workflowName = store.workflowName ?? 'bp_flow';
    
    debugPrint('[KycCompletedPage] Stepper data - company: $_company, workflowName: $workflowName, workflowId: $_workflowId, position: $_currentPosition');
    
    // Fetch stepper workflow if we have workflowId and it's not already loaded
    if (_workflowId != null && _workflowId!.isNotEmpty) {
      if (store.stepperWorkflow == null && !store.loadingStepperWorkflow) {
        debugPrint('[KycCompletedPage] Fetching stepper workflow: $workflowName / $_workflowId');
        // Backend route: /kycadmin_getWorkflow/{workflowName}/{workflowId}
        store.fetchStepperWorkflow(workflowName, _workflowId!);
      }
    } else {
      debugPrint('[KycCompletedPage] Missing workflowId or company. workflowId: $_workflowId, company: $_company');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final userDetails = store.userDetails;
    
    // Extract user details from API response
    final response = userDetails is Map ? userDetails as Map<String, dynamic>? : null;
    final data = response?['data'] as Map<String, dynamic>?;
    
    final name = data?['aadhar_name']?.toString() ?? 'N/A';
    final pan = data?['temp_pan_no']?.toString() ?? 'N/A';
    final phone = data?['change_mobile']?.toString() ?? data?['mobile_number']?.toString() ?? 'N/A';
    final aadhaar = data?['aadhar_no']?.toString() ?? '';
    final maskedAadhaar = aadhaar.isNotEmpty && aadhaar.length >= 4
        ? 'XXXX-XXXX-${aadhaar.substring(aadhaar.length - 4)}'
        : 'N/A';

    // Stepper not shown on KYC completed page - removed stepper-related code
    
    final completedSteps = _getCompletedSteps(data);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // Main content
                Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const SizedBox(height: 20),
                    // Success indicator with rings
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // Outer ring
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.green.withOpacity(0.1),
                          ),
                        ),
                        // Middle ring
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.green.withOpacity(0.15),
                          ),
                        ),
                        // Inner circle with checkmark
                        Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.green,
                          ),
                          child: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 50,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 25),
                    // KYC Completed heading
                    const Text(
                      'KYC Completed',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Verification message
                    Text(
                      'Your account will be verified in 48 hr',
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 40),
                    // Customer Details card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Customer Details',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _buildDetailRow('Name', name),
                                    const SizedBox(height: 10),
                                    _buildDetailRow('Pan', pan),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _buildDetailRow('Phone', phone),
                                      const SizedBox(height: 10),
                                    _buildDetailRow('Aadhaar', maskedAadhaar),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Completed Steps section
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Completed Steps',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    // Steps list
                    ...completedSteps.map((step) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.green,
                                ),
                                child: const Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  step,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
              ],
            ),
            Positioned(
              top: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: IconButton(
                  icon: const Icon(Icons.logout, color: KycTheme.textPrimary),
                  onPressed: () => _showLogoutConfirmation(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLogoutConfirmation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await StorageService.clearAll();
    // Post-logout: SSO-only login on HomePage (_loadWorkflow auto-SSO).
    // StorageService.setSsoAutoLoginEnabled(false);
    StorageService.setSsoAutoLoginEnabled(true);
    if (!context.mounted) return;
    context.read<AppStore>().resetState();
    context.go('/${widget.company}/${widget.workflowName}');
  }

  Widget _buildStepper(List<String> steps, int? currentPositionIndex) {
    if (steps.isEmpty) {
      debugPrint('[KycCompletedPage] No steps available for stepper');
      return const SizedBox(
        height: 40,
        child: Center(
          child: Text(
            'No steps available',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      );
    }
    
    debugPrint('[KycCompletedPage] Building stepper with ${steps.length} steps, currentIndex: $currentPositionIndex');
    
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(steps.length * 2 - 1, (i) {
          if (i.isOdd) {
            // Connector arrow
            final prevIdx = (i - 1) ~/ 2;
            final isSegmentDone = currentPositionIndex != null && currentPositionIndex! > prevIdx;
            return Padding(
              padding: const EdgeInsets.only(top: 14, left: 2, right: 2),
              child: Icon(
                Icons.arrow_forward_ios,
                size: 12,
                color: isSegmentDone ? Colors.green : Colors.grey[300]!,
              ),
            );
          }
          final idx = i ~/ 2;
          final stepName = steps[idx];
          // IMPORTANT: Only steps BEFORE currentPositionIndex are completed
          // Current step (idx == currentPositionIndex) should be ACTIVE, NOT completed
          final isPast = currentPositionIndex != null && idx < currentPositionIndex!;
          final isActive = currentPositionIndex != null && idx == currentPositionIndex;
          
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Step circle
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isPast || isActive
                        ? Colors.green
                        : Colors.grey[300],
                  ),
                  child: Center(
                    // Show checkmark ONLY for completed steps (isPast), NOT for current step
                    child: isPast
                        ? const Icon(Icons.check, size: 18, color: Colors.white)
                        : Text(
                            '${idx + 1}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isActive || isPast
                                  ? Colors.white
                                  : Colors.grey[700]!,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 6),
                // Step label (format label)
                Text(
                  KycStepperBar.formatLabel(stepName),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    color: isActive || isPast
                        ? Colors.green
                        : Colors.grey[600]!,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
        }),
      ),
    );
  }


  Widget _buildDetailRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  List<String> _getCompletedSteps(Map<String, dynamic>? data) {
    // Default steps - can be customized based on API response
    final steps = <String>[
      'Mobile and Email Verification',
      'Brokerage Plan Selected',
      'Pan Verified',
      'Aadhaar Verification',
      'Photo Verification',
      'Other Details Filled',
      'Bank Details Submitted',
      'E-Sign Done',
    ];

    // If API provides steps list, use that instead
    if (data != null && data['completed_steps'] is List) {
      return (data['completed_steps'] as List)
          .map((e) => e.toString())
          .toList();
    }

    return steps;
  }
}
