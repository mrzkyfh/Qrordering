import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../bloc/auth_bloc.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/utils/humanize_error.dart';

/// Login akun perangkat cabang (gerbang keamanan). Dilakukan sekali per
/// perangkat; setelah ini karyawan cukup pilih nama + PIN (clock-in).
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  String _version = '';

  @override
  void initState() {
    super.initState();
    // Tampilkan versi ASLI (untuk support), bukan string hardcode yang usang.
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = 'v${info.version}');
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.read<AuthBloc>().add(AuthDeviceLoginRequested(
          email: _emailCtrl.text.trim(),
          password: _passCtrl.text,
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthError) {
            AppToast.error(context, humanizeError(state.message),
                title: 'Login perangkat gagal');
          }
        },
        builder: (context, state) {
          final loading = state is AuthLoading;
          return SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.25),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Image.asset('assets/images/logo.png',
                              fit: BoxFit.cover),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text('Times 420',
                          style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 6),
                      const Text('Aktifkan perangkat untuk cabang ini',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 14)),
                      const SizedBox(height: 32),
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Login Akun Perangkat',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: -0.3)),
                              const SizedBox(height: 4),
                              const Text(
                                  'Pakai email & password akun cabang dari owner. ',
                                  style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 13)),
                              const SizedBox(height: 22),
                              const _Label('Email'),
                              const SizedBox(height: 7),
                              TextFormField(
                                controller: _emailCtrl,
                                keyboardType: TextInputType.emailAddress,
                                style: const TextStyle(fontSize: 14),
                                decoration: _inputDec(
                                  hint: 'cabang@restoran.com',
                                  prefix: const Icon(Icons.mail_outline_rounded,
                                      size: 18, color: AppColors.textSecondary),
                                ),
                                validator: (v) => v != null && v.contains('@')
                                    ? null
                                    : 'Email tidak valid',
                              ),
                              const SizedBox(height: 16),
                              const _Label('Password'),
                              const SizedBox(height: 7),
                              TextFormField(
                                controller: _passCtrl,
                                obscureText: _obscure,
                                style: const TextStyle(fontSize: 14),
                                decoration: _inputDec(
                                  hint: 'Password akun cabang',
                                  prefix: const Icon(Icons.lock_outline_rounded,
                                      size: 18, color: AppColors.textSecondary),
                                  suffix: IconButton(
                                    icon: Icon(
                                        _obscure
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        size: 18,
                                        color: AppColors.textSecondary),
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                  ),
                                ),
                                validator: (v) => v != null && v.length >= 6
                                    ? null
                                    : 'Password minimal 6 karakter',
                              ),
                              const SizedBox(height: 26),
                              SizedBox(
                                width: double.infinity,
                                height: 50,
                                child: FilledButton(
                                  onPressed: loading ? null : _submit,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppColors.primary,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14)),
                                    elevation: 0,
                                  ),
                                  child: loading
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white))
                                      : const Text('Aktifkan Perangkat',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15,
                                              letterSpacing: 0.2)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text('Times 420${_version.isEmpty ? '' : ' · $_version'}',
                          style: TextStyle(
                              color: AppColors.textDisabled, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  InputDecoration _inputDec({
    required String hint,
    Widget? prefix,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textDisabled, fontSize: 14),
      prefixIcon: prefix,
      suffixIcon: suffix,
      filled: true,
      fillColor: const Color(0xFFF6F7FB),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary));
  }
}
