import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:swastik_mobile_app/core/utils/time_utils.dart';
import 'package:swastik_mobile_app/core/utils/formatters.dart';
import 'package:swastik_mobile_app/core/models/party_model.dart';
import 'package:swastik_mobile_app/core/models/transaction_model.dart';
import 'package:swastik_mobile_app/core/utils/responsive_utils.dart';
import 'package:swastik_mobile_app/features/navigation/presentation/providers/navigation_provider.dart';
import 'package:swastik_mobile_app/features/parties/providers/party_providers.dart';
import 'package:swastik_mobile_app/features/ledger/providers/transaction_providers.dart';
import 'package:swastik_mobile_app/features/parties/presentation/widgets/quick_add_party_bottom_sheet.dart';
import 'package:swastik_mobile_app/features/auth/providers/auth_providers.dart';

class EntriesScreen extends ConsumerStatefulWidget {
  const EntriesScreen({super.key});

  @override
  ConsumerState<EntriesScreen> createState() => _EntriesScreenState();
}

class _EntriesScreenState extends ConsumerState<EntriesScreen> {
  String _transactionType = 'IN';
  String _category = 'Money'; // Money, Gold, Diamond
  String _paymentMode = 'Cash'; // Cash, UPI, RTGS
  DateTime _selectedDate = TimeUtils.now;
  TimeOfDay _selectedTime = TimeOfDay.fromDateTime(TimeUtils.now);
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _partyController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _purityController = TextEditingController();
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _caratController = TextEditingController();
  final TextEditingController _piecesController = TextEditingController();
  final FocusNode _partyFocusNode = FocusNode();
  PartyModel? _selectedParty;
  String? _pendingPartyId;

  Timer? _clockTimer;
  bool _isTimeManuallySet = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = TimeUtils.now;
    _selectedTime = TimeOfDay.fromDateTime(TimeUtils.now);

    // Update time when the minute/hour changes, avoiding 60 full-screen rebuilds per minute
    _clockTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        final now = TimeUtils.now;
        final newTime = TimeOfDay.fromDateTime(now);
        if (newTime.minute != _selectedTime.minute || newTime.hour != _selectedTime.hour) {
          setState(() {
            if (!_isTimeManuallySet) {
              _selectedDate = now;
            }
            _selectedTime = newTime;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _amountController.dispose();
    _partyController.dispose();
    _notesController.dispose();
    _purityController.dispose();
    _weightController.dispose();
    _caratController.dispose();
    _piecesController.dispose();
    _partyFocusNode.dispose();
    super.dispose();
  }

  TextStyle _textStyle(BuildContext context, TextStyle baseStyle) {
    final isTablet = AppResponsive.isTablet(context);
    if (isTablet) {
      final double size = baseStyle.fontSize ?? 14;
      final double scaledSize = size >= 20 ? size + 4.0 : size + 3.0;
      return GoogleFonts.montserrat(
        fontSize: scaledSize,
        fontWeight: baseStyle.fontWeight,
        color: baseStyle.color,
        letterSpacing: baseStyle.letterSpacing,
        height: baseStyle.height,
      );
    }
    return baseStyle;
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = AppResponsive.isTablet(context);
    final isStaff = ref.watch(isStaffProvider);

    // Listen to parties stream to auto-select pending party if it was added via Quick Add
    ref.listen<AsyncValue<List<PartyModel>>>(partiesStreamProvider, (
      prev,
      next,
    ) {
      if (_pendingPartyId != null && next.hasValue) {
        final list = next.value ?? [];
        final found = list.where((p) => p.id == _pendingPartyId).firstOrNull;
        if (found != null) {
          setState(() {
            _selectedParty = found;
            _partyController.text = found.name;
            _pendingPartyId = null;
          });
        }
      }
    });

    return Scaffold(
      backgroundColor: isTablet ? const Color(0xFFFAF6EE) : const Color(0xFFFDFBF7),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: BoxConstraints(
              maxWidth: isTablet ? 720 : double.infinity,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: isTablet ? 32.0 : 20.0,
                vertical: isTablet ? 28.0 : 24.0,
              ),
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'New Entry',
                        style: _textStyle(
                          context,
                          const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Record transaction details.',
                        style: _textStyle(
                          context,
                          TextStyle(fontSize: 14, color: Colors.grey.shade700),
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _buildDateTimePicker(
                        icon: Icons.calendar_today_outlined,
                        text: DateFormat('dd MMM yyyy').format(_selectedDate),
                        showArrow: true,
                        onTap: isStaff ? null : () async {
                          final DateTime? picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setState(() {
                              _selectedDate = picked;
                              _isTimeManuallySet = true;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildDateTimePicker(
                        icon: Icons.access_time_outlined,
                        text: _selectedTime.format(context),
                        onTap: null, // Time cannot be changed, must always be current time
                      ),
                    ],
                  ),
                ],
              ),
              SizedBox(height: isTablet ? 40 : 32),

              // IN / OUT Toggle
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF4EDE4),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildTransactionTypeButton(
                        title: 'IN (Receive)',
                        icon: Icons.arrow_downward,
                        selectedColor: const Color(0xFF8A7311),
                        isSelected: _transactionType == 'IN',
                        onTap: () => setState(() => _transactionType = 'IN'),
                      ),
                    ),
                    Expanded(
                      child: _buildTransactionTypeButton(
                        title: 'OUT (Give)',
                        icon: Icons.arrow_upward,
                        selectedColor: Colors.black87,
                        isSelected: _transactionType == 'OUT',
                        onTap: () => setState(() => _transactionType = 'OUT'),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: isTablet ? 32 : 24),

              // Party / Customer
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Party / Customer',
                    style: _textStyle(
                      context,
                      const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () async {
                      final newId = await showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => const QuickAddPartyBottomSheet(),
                      );
                      if (newId != null && newId is String) {
                        final list = ref.read(partiesStreamProvider).value ?? [];
                        final found = list.where((p) => p.id == newId).firstOrNull;
                        if (found != null) {
                          setState(() {
                            _selectedParty = found;
                            _partyController.text = found.name;
                            _pendingPartyId = null;
                          });
                        } else {
                          setState(() => _pendingPartyId = newId);
                        }
                      }
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isTablet ? 18 : 12,
                        vertical: isTablet ? 10 : 6,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFDCAE3D)),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.add,
                            size: isTablet ? 20 : 16,
                            color: const Color(0xFF8A7311),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Add New',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF8A7311),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildPartyAutocomplete(isTablet),
              SizedBox(height: isTablet ? 32 : 24),

              // Category Toggle
              Text(
                'Category',
                style: _textStyle(
                  context,
                  const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF4EDE4),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    _buildCategoryButton('Money'),
                    _buildCategoryButton('Gold'),
                    _buildCategoryButton('Diamond'),
                  ],
                ),
              ),
              SizedBox(height: isTablet ? 32 : 24),

              // Dynamic Fields based on Category
              if (_category == 'Money') ...[
                Container(
                  padding: EdgeInsets.all(isTablet ? 24 : 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Payment Mode
                      Text(
                        'Payment Mode',
                        style: _textStyle(
                          context,
                          const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _buildPaymentModeChip('Cash'),
                          const SizedBox(width: 12),
                          _buildPaymentModeChip('UPI'),
                          const SizedBox(width: 12),
                          _buildPaymentModeChip('RTGS'),
                        ],
                      ),
                      SizedBox(height: isTablet ? 28 : 20),

                      // Amount
                      Text(
                        'Amount',
                        style: _textStyle(
                          context,
                          const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _amountController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          _IndianCurrencyFormatter(),
                        ],
                        style: _textStyle(
                          context,
                          const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        decoration: InputDecoration(
                          hintText: '0',
                          hintStyle: _textStyle(
                            context,
                            TextStyle(
                              color: Colors.grey.shade300,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          prefixIcon: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: isTablet ? 20 : 14,
                                vertical: isTablet ? 12 : 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF4EDE4),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '₹',
                                style: _textStyle(
                                  context,
                                  const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF8A7311),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 0,
                            minHeight: 0,
                          ),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: isTablet ? 20 : 16,
                            vertical: isTablet ? 18 : 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: Colors.grey.shade400),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: Colors.grey.shade400),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: Color(0xFF8A7311),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: isTablet ? 32 : 24),
              ],

              if (_category == 'Gold') ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Purity %',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _purityController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textAlign: TextAlign.right,
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 16,
                                color: Colors.black87,
                              ),
                            ),
                            decoration: InputDecoration(
                              hintText: '99.5',
                              hintStyle: _textStyle(
                                context,
                                TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 16,
                                ),
                              ),
                              suffixIcon: Padding(
                                padding: const EdgeInsets.only(right: 16.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      '%',
                                      style: _textStyle(
                                        context,
                                        TextStyle(
                                          fontSize: 18,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              suffixIconConstraints: const BoxConstraints(
                                minWidth: 0,
                                minHeight: 0,
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: isTablet ? 20 : 16,
                                vertical: isTablet ? 22 : 18,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade400,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Weight (g)',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _weightController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textAlign: TextAlign.right,
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 16,
                                color: Colors.black87,
                              ),
                            ),
                            decoration: InputDecoration(
                              hintText: '0.00',
                              hintStyle: _textStyle(
                                context,
                                TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 16,
                                ),
                              ),
                              suffixIcon: Padding(
                                padding: const EdgeInsets.only(right: 16.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      'g',
                                      style: _textStyle(
                                        context,
                                        TextStyle(
                                          fontSize: 18,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              suffixIconConstraints: const BoxConstraints(
                                minWidth: 0,
                                minHeight: 0,
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: isTablet ? 20 : 16,
                                vertical: isTablet ? 22 : 18,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade400,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: isTablet ? 32 : 24),
              ],

              if (_category == 'Diamond') ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CARAT (CT)',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _caratController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textAlign: TextAlign.center,
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                            decoration: InputDecoration(
                              hintText: '0.00',
                              hintStyle: _textStyle(
                                context,
                                TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: isTablet ? 20 : 16,
                                vertical: isTablet ? 22 : 18,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade400,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PIECES',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _piecesController,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                            decoration: InputDecoration(
                              hintText: '0',
                              hintStyle: _textStyle(
                                context,
                                TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: isTablet ? 20 : 16,
                                vertical: isTablet ? 22 : 18,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey.shade400,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: isTablet ? 32 : 24),
              ],

              // Particulars / Notes
              Text(
                'Particulars / Notes',
                style: _textStyle(
                  context,
                  const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notesController,
                textCapitalization: TextCapitalization.characters,
                maxLines: 3,
                style: _textStyle(
                  context,
                  const TextStyle(fontSize: 15, color: Colors.black87),
                ),
                decoration: InputDecoration(
                  hintText:
                      'Add details about the metal quality,\nhallmark, etc...',
                  hintStyle: _textStyle(
                    context,
                    TextStyle(color: Colors.grey.shade500, fontSize: 15),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: EdgeInsets.all(isTablet ? 20 : 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade400),
                  ),
                ),
              ),
              SizedBox(height: isTablet ? 40 : 32),

              // Bottom Buttons
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        // Clear inputs
                        _partyController.clear();
                        _amountController.clear();
                        _notesController.clear();
                        _purityController.clear();
                        _weightController.clear();
                        _caratController.clear();
                        _piecesController.clear();
                        setState(() {
                          _selectedParty = null;
                          _isTimeManuallySet = false;
                        });
                      },
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          vertical: isTablet ? 20 : 16,
                        ),
                        backgroundColor: const Color(0xFFF4EDE4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: Text(
                        'Cancel',
                        style: _textStyle(
                          context,
                          const TextStyle(
                            color: Colors.black87,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : () async {
                        if (_selectedParty == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Please select a party'),
                            ),
                          );
                          return;
                        }

                        setState(() { _isSaving = true; });

                        try {
                          // Determine TransactionType
                          TransactionType tType = TransactionType.sale; // default
                          if (_transactionType == 'IN') {
                            if (_category == 'Money')
                              tType = TransactionType.receipt;
                            else
                              tType = TransactionType.metalIn;
                          } else {
                            if (_category == 'Money')
                              tType = TransactionType.payment;
                            else
                              tType = TransactionType.metalOut;
                          }

                          // Determine PaymentMode
                          PaymentMode pMode = PaymentMode.cash;
                          if (_category == 'Money') {
                            if (_paymentMode == 'Cash')
                              pMode = PaymentMode.cash;
                            else if (_paymentMode == 'UPI')
                              pMode = PaymentMode.upi;
                            else if (_paymentMode == 'RTGS')
                              pMode = PaymentMode.rtgs;
                            else
                              pMode = PaymentMode.online;
                          } else {
                            pMode = PaymentMode.metal;
                          }

                          // Parse values
                          double cashAmt =
                              double.tryParse(
                                _amountController.text.replaceAll(',', ''),
                              ) ??
                              0.0;
                          double metalWt = 0.0;
                          if (_category == 'Gold')
                            metalWt =
                                double.tryParse(_weightController.text) ?? 0.0;
                          if (_category == 'Diamond')
                            metalWt =
                                double.tryParse(_caratController.text) ?? 0.0;

                          String metalP = '';
                          if (_category == 'Gold')
                            metalP = _purityController.text;
                          if (_category == 'Diamond')
                            metalP = '${_piecesController.text} p';

                          final date = DateTime(
                            _selectedDate.year,
                            _selectedDate.month,
                            _selectedDate.day,
                            _selectedTime.hour,
                            _selectedTime.minute,
                          );

                          final success = await ref
                              .read(transactionNotifierProvider.notifier)
                              .createTransaction(
                                partyId: _selectedParty!.id,
                                partyName: _selectedParty!.name,
                                partyPhone: _selectedParty!.phone,
                                type: tType,
                                paymentMode: pMode,
                                cashAmount: cashAmt,
                                metalType: _category == 'Money'
                                    ? ''
                                    : _category.toLowerCase(),
                                metalWeight: metalWt,
                                metalPurity: metalP,
                                notes: _notesController.text,
                                date: date,
                              );

                          if (success && mounted) {
                            // Switch to ledger screen on tablet, home screen on mobile
                            ref.read(navigationProvider.notifier).setIndex(isTablet ? 2 : 0);

                            // Reset fields
                            _partyController.clear();
                            _amountController.clear();
                            _notesController.clear();
                            _purityController.clear();
                            _weightController.clear();
                            _caratController.clear();
                            _piecesController.clear();
                            setState(() {
                              _selectedParty = null;
                              _isTimeManuallySet = false;
                            });

                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Entry saved successfully'),
                              ),
                            );
                          } else if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Save may have failed. Please check ledger before retrying.'),
                              ),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() { _isSaving = false; });
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          vertical: isTablet ? 20 : 16,
                        ),
                        backgroundColor: const Color(0xFFDCAE3D),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: _isSaving 
                          ? SizedBox(
                              width: isTablet ? 24 : 20,
                              height: isTablet ? 24 : 20,
                              child: const CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.black87,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.check,
                                  color: Colors.black87,
                                  size: isTablet ? 24 : 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Save Entry',
                                  style: _textStyle(
                                    context,
                                    const TextStyle(
                                      color: Colors.black87,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 80), // Padding for bottom nav bar
            ],
          ),
        ),
      ),
    ),
  ),
);
  }

  Widget _buildPartyAutocomplete(bool isTablet) {
    return LayoutBuilder(
      builder: (context, constraints) => RawAutocomplete<PartyModel>(
        focusNode: _partyFocusNode,
        textEditingController: _partyController,
        optionsBuilder: (TextEditingValue textEditingValue) {
          final queryText = textEditingValue.text.trim();
          final queryLower = queryText.toLowerCase();
          final parties = ref.read(partiesStreamProvider).value ?? [];

          if (queryText.isEmpty) {
            final recent = parties.toList()
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
            return recent.take(5);
          }

          final matches = parties.where((party) {
            return party.name.toLowerCase().contains(queryLower) ||
                party.phone.contains(queryLower);
          }).toList();

          final hasExactMatch = matches.any((party) => party.name.toLowerCase() == queryLower);
          if (!hasExactMatch) {
            matches.add(
              PartyModel(
                id: 'ADD_NEW_PARTY_PLACEHOLDER',
                name: queryText,
                type: '',
                phone: '',
                email: '',
                address: '',
                cashBalance: 0.0,
                goldBalanceGrams: 0.0,
                silverBalanceGrams: 0.0,
                diamondBalanceCarats: 0.0,
                openingCashBalance: 0.0,
                openingGoldBalanceGrams: 0.0,
                openingDiamondBalanceCarats: 0.0,
                createdAt: TimeUtils.now,
                updatedAt: TimeUtils.now,
              ),
            );
          }

          return matches;
        },
        displayStringForOption: (PartyModel option) => option.name,
        onSelected: (PartyModel selection) async {
          if (selection.id == 'ADD_NEW_PARTY_PLACEHOLDER') {
            final newId = await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (context) => QuickAddPartyBottomSheet(initialName: selection.name),
            );
            if (newId != null && newId is String) {
              final list = ref.read(partiesStreamProvider).value ?? [];
              final found = list.where((p) => p.id == newId).firstOrNull;
              if (found != null) {
                setState(() {
                  _selectedParty = found;
                  _partyController.text = found.name;
                  _pendingPartyId = null;
                });
              } else {
                setState(() => _pendingPartyId = newId);
              }
            } else {
              _partyController.clear();
              setState(() => _selectedParty = null);
            }
          } else {
            setState(() => _selectedParty = selection);
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _partyFocusNode.unfocus();
          });
        },
        fieldViewBuilder:
            (context, textEditingController, focusNode, onFieldSubmitted) {
              return TextField(
                controller: textEditingController,
                focusNode: focusNode,
                inputFormatters: [UpperCaseTextFormatter()],
                style: _textStyle(
                  context,
                  const TextStyle(fontSize: 15, color: Colors.black87),
                ),
                decoration: InputDecoration(
                  hintText: 'Search party name or phone...',
                  hintStyle: _textStyle(
                    context,
                    TextStyle(color: Colors.grey.shade500, fontSize: 15),
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    color: Colors.black54,
                    size: isTablet ? 24 : 20,
                  ),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: isTablet ? 18 : 14,
                    horizontal: 16,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade400),
                  ),
                  suffixIcon:
                      _selectedParty != null ||
                          textEditingController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, size: isTablet ? 24 : 20),
                          onPressed: () {
                            textEditingController.clear();
                            setState(() => _selectedParty = null);
                          },
                        )
                      : null,
                ),
                onSubmitted: (String value) {
                  onFieldSubmitted();
                },
              );
            },
        optionsViewBuilder: (context, onSelected, options) {
          return Align(
            alignment: Alignment.topLeft,
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              tween: Tween(begin: 0.0, end: 1.0),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 10 * (1 - value)),
                    child: child,
                  ),
                );
              },
              child: Material(
                elevation: 8,
                shadowColor: Colors.black.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: 250,
                    maxWidth: constraints.maxWidth,
                  ),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (BuildContext context, int index) {
                      final option = options.elementAt(index);
                      final isPlaceholder = option.id == 'ADD_NEW_PARTY_PLACEHOLDER';

                      if (isPlaceholder) {
                        return ListTile(
                          leading: CircleAvatar(
                            radius: isTablet ? 24 : 20,
                            backgroundColor: const Color(0xFFFFEEB3),
                            child: Icon(
                              Icons.add,
                              color: const Color(0xFF8A7311),
                              size: isTablet ? 24 : 20,
                            ),
                          ),
                          title: Text(
                            'Create new: "${option.name}"',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF8A7311),
                              ),
                            ),
                          ),
                          subtitle: Text(
                            'Tap to add customer details',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                          onTap: () => onSelected(option),
                        );
                      }

                      return ListTile(
                        leading: CircleAvatar(
                          radius: isTablet ? 24 : 20,
                          backgroundColor: const Color(0xFFF4EDE4),
                          child: Text(
                            option.name.isNotEmpty
                                ? option.name[0].toUpperCase()
                                : '?',
                            style: _textStyle(
                              context,
                              const TextStyle(
                                color: Color(0xFF8A7311),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        title: _buildHighlightText(
                          option.name,
                          _partyController.text,
                          isTablet,
                        ),
                        subtitle: option.phone.isNotEmpty
                            ? Text(
                                option.phone,
                                style: _textStyle(
                                  context,
                                  const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              )
                            : null,
                        onTap: () => onSelected(option),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHighlightText(String text, String query, bool isTablet) {
    if (query.isEmpty) {
      return Text(
        text,
        style: _textStyle(
          context,
          const TextStyle(fontWeight: FontWeight.w500, color: Colors.black87),
        ),
      );
    }
    final matchIndex = text.toLowerCase().indexOf(query.toLowerCase());
    if (matchIndex == -1) {
      return Text(
        text,
        style: _textStyle(
          context,
          const TextStyle(fontWeight: FontWeight.w500, color: Colors.black87),
        ),
      );
    }
    return RichText(
      text: TextSpan(
        text: text.substring(0, matchIndex),
        style: _textStyle(
          context,
          const TextStyle(color: Colors.black87, fontWeight: FontWeight.w500),
        ),
        children: [
          TextSpan(
            text: text.substring(matchIndex, matchIndex + query.length),
            style: _textStyle(
              context,
              const TextStyle(
                color: Color(0xFFDCAE3D),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          TextSpan(
            text: text.substring(matchIndex + query.length),
            style: _textStyle(
              context,
              const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionTypeButton({
    required String title,
    required IconData icon,
    required Color selectedColor,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final isTablet = AppResponsive.isTablet(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: isTablet ? 16 : 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? selectedColor : Colors.black54,
              size: isTablet ? 22 : 18,
            ),
            SizedBox(width: isTablet ? 10 : 8),
            Text(
              title,
              style: _textStyle(
                context,
                TextStyle(
                  color: isSelected ? selectedColor : Colors.black54,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryButton(String category) {
    final isSelected = _category == category;
    final isTablet = AppResponsive.isTablet(context);
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _category = category),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: isTablet ? 16 : 12),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: Text(
              category,
              style: _textStyle(
                context,
                TextStyle(
                  color: isSelected ? const Color(0xFF8A7311) : Colors.black54,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentModeChip(String mode) {
    final isSelected = _paymentMode == mode;
    final isTablet = AppResponsive.isTablet(context);
    return GestureDetector(
      onTap: () => setState(() => _paymentMode = mode),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isTablet ? 28 : 20,
          vertical: isTablet ? 14 : 10,
        ),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFDF9EE) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFFDCAE3D) : Colors.grey.shade300,
          ),
        ),
        child: Text(
          mode,
          style: _textStyle(
            context,
            TextStyle(
              color: isSelected ? const Color(0xFF8A7311) : Colors.black87,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDateTimePicker({
    required IconData icon,
    required String text,
    VoidCallback? onTap,
    bool showArrow = false,
  }) {
    final isTablet = AppResponsive.isTablet(context);
    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: isTablet ? 14 : 10,
        vertical: isTablet ? 10 : 6,
      ),
      decoration: BoxDecoration(
        color: onTap != null ? Colors.white : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: onTap != null ? [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ] : [],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: isTablet ? 18 : 14, color: Colors.grey.shade800),
          SizedBox(width: isTablet ? 8 : 6),
          Text(
            text,
            style: _textStyle(
              context,
              TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
          ),
          if (showArrow && onTap != null) ...[
            SizedBox(width: isTablet ? 4 : 2),
            Icon(Icons.arrow_drop_down, size: isTablet ? 20 : 16, color: Colors.grey.shade800),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return content;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }
}

class _IndianCurrencyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) {
      return newValue.copyWith(text: '');
    }

    // Only allow numbers
    String cleanText = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanText.isEmpty) {
      return newValue.copyWith(text: '');
    }

    try {
      int value = int.parse(cleanText);
      final formatter = NumberFormat.decimalPattern('en_IN');
      String formattedText = formatter.format(value);

      return newValue.copyWith(
        text: formattedText,
        selection: TextSelection.collapsed(offset: formattedText.length),
      );
    } catch (e) {
      return oldValue;
    }
  }
}
