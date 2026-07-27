import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'otp_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late PageController _pageController;
  int _currentPage = 0;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login'),
        elevation: 0,
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() => _currentPage = index);
        },
        children: [
          _buildEmailLoginPage(context),
          _buildPhoneLoginPage(context),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: _currentPage == 0
                  ? null
                  : () => _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
              child: const Text('Email Login'),
            ),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _currentPage == 0
                    ? Theme.of(context).primaryColor
                    : Colors.grey,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _currentPage == 1
                    ? Theme.of(context).primaryColor
                    : Colors.grey,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _currentPage == 1
                  ? null
                  : () => _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
              child: const Text('Phone Login'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailLoginPage(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          Icon(
            Icons.email,
            size: 64,
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(height: 24),
          Text(
            'Login with Email',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _emailController,
            decoration: InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.email_outlined),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.lock_outlined),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 24),
          Consumer<AuthProvider>(
            builder: (context, authProvider, _) {
              return ElevatedButton(
                onPressed: authProvider.isLoading
                    ? null
                    : () => _handleEmailLogin(context, authProvider),
                child: authProvider.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Login'),
              );
            },
          ),
          const SizedBox(height: 16),
          if (context.watch<AuthProvider>().errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                context.watch<AuthProvider>().errorMessage!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPhoneLoginPage(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          Icon(
            Icons.phone,
            size: 64,
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(height: 24),
          Text(
            'Login with Phone',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _phoneController,
            decoration: InputDecoration(
              labelText: 'Phone Number',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.phone_outlined),
              hintText: '+212612345678',
            ),
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 24),
          Consumer<AuthProvider>(
            builder: (context, authProvider, _) {
              return ElevatedButton(
                onPressed: authProvider.isLoading
                    ? null
                    : () => _handlePhoneLogin(context, authProvider),
                child: authProvider.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send OTP'),
              );
            },
          ),
          const SizedBox(height: 16),
          if (context.watch<AuthProvider>().errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                context.watch<AuthProvider>().errorMessage!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _handleEmailLogin(
    BuildContext context,
    AuthProvider authProvider,
  ) async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields')),
      );
      return;
    }

    final success = await authProvider.loginWithEmail(
      email: _emailController.text,
      password: _passwordController.text,
    );

    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login successful')),
      );
    }
  }

  Future<void> _handlePhoneLogin(
    BuildContext context,
    AuthProvider authProvider,
  ) async {
    if (_phoneController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a phone number')),
      );
      return;
    }

    final success = await authProvider.loginWithPhone(
      phone: _phoneController.text,
    );

    if (success) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OtpScreen(phone: _phoneController.text),
        ),
      );
    }
  }
}
