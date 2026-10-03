import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:databric/providers/auth_provider.dart';
import 'package:databric/theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  bool _otpSent = false;
  String _phoneNumber = '';

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) return;

    final auth = context.read<AuthProvider>();
    final success = await auth.sendOtp(phone);

    if (success && mounted) {
      setState(() {
        _otpSent = true;
        _phoneNumber = phone;
      });
    } else if (mounted && auth.error != null) {
      _showError(auth.error!);
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) return;

    final auth = context.read<AuthProvider>();
    final success = await auth.verifyOtp(_phoneNumber, otp);

    // No manual navigation — _AppEntry watches AuthProvider and rebuilds
    // into HomeScreen when status flips to authenticated.
    if (!success && mounted && auth.error != null) {
      _showError(auth.error!);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.sent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              const Text(
                'DataBric',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _otpSent
                    ? 'Enter the 6-digit code\nsent to $_phoneNumber'
                    : 'Share data with friends,\nacross any network.',
                style: const TextStyle(
                  fontSize: 20,
                  color: AppTheme.textSecondary,
                  height: 1.4,
                ),
              ),
              const Spacer(),

              if (!_otpSent) ...[
                Text('Phone number', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[+0-9]'))],
                  decoration: const InputDecoration(
                    hintText: '+250 78 000 0000',
                    prefixIcon: Icon(Icons.phone_outlined, size: 20),
                  ),
                  onSubmitted: (_) => _sendOtp(),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: auth.isLoading ? null : _sendOtp,
                  child: auth.isLoading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white,
                          ),
                        )
                      : const Text('Send verification code'),
                ),
              ] else ...[
                Text('Verification code', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 12,
                  ),
                  decoration: const InputDecoration(
                    hintText: '------',
                    counterText: '',
                  ),
                  onChanged: (v) {
                    if (v.length == 6) _verifyOtp();
                  },
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => setState(() { _otpSent = false; }),
                  child: const Text('Change phone number'),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: auth.isLoading ? null : _verifyOtp,
                  child: auth.isLoading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white,
                          ),
                        )
                      : const Text('Verify and continue'),
                ),
              ],
              const SizedBox(height: 32),
              Center(
                child: Text(
                  'By continuing you agree to our Terms of Service.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
