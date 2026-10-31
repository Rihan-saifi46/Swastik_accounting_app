import '../utils/time_utils.dart';

enum TransactionType { sale, purchase, payment, receipt, metalIn, metalOut, return_ }

enum PaymentMode { cash, online, metal, mixed, upi, rtgs }

class TransactionModel {
  final String id;
  final String partyId;
  final String partyName;
  final String partyPhone;
  final TransactionType type;
  final PaymentMode paymentMode;
  final double cashAmount;
  final String metalType; // 'gold', 'silver', 'diamond', ''
  final double metalWeight;
  final String metalPurity; // '24K', '22K', '18K', ''
  final String notes;
  final DateTime date;
  final DateTime createdAt;
  final String? createdBy;
  final String? updatedBy;
  final DateTime? updatedAt;

  const TransactionModel({
    required this.id,
    required this.partyId,
    required this.partyName,
    required this.partyPhone,
    required this.type,
    required this.paymentMode,
    required this.cashAmount,
    required this.metalType,
    required this.metalWeight,
    required this.metalPurity,
    required this.notes,
    required this.date,
    required this.createdAt,
    this.createdBy,
    this.updatedBy,
    this.updatedAt,
  });

  TransactionModel copyWith({
    String? id,
    String? partyId,
    String? partyName,
    String? partyPhone,
    TransactionType? type,
    PaymentMode? paymentMode,
    double? cashAmount,
    String? metalType,
    double? metalWeight,
    String? metalPurity,
    String? notes,
    DateTime? date,
    DateTime? createdAt,
    String? createdBy,
    String? updatedBy,
    DateTime? updatedAt,
  }) {
    return TransactionModel(
      id: id ?? this.id,
      partyId: partyId ?? this.partyId,
      partyName: partyName ?? this.partyName,
      partyPhone: partyPhone ?? this.partyPhone,
      type: type ?? this.type,
      paymentMode: paymentMode ?? this.paymentMode,
      cashAmount: cashAmount ?? this.cashAmount,
      metalType: metalType ?? this.metalType,
      metalWeight: metalWeight ?? this.metalWeight,
      metalPurity: metalPurity ?? this.metalPurity,
      notes: notes ?? this.notes,
      date: date ?? this.date,
      createdAt: createdAt ?? this.createdAt,
      createdBy: createdBy ?? this.createdBy,
      updatedBy: updatedBy ?? this.updatedBy,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory TransactionModel.fromMap(String id, Map<String, dynamic> map) {
    return TransactionModel(
      id: id,
      partyId: map['partyId'] as String? ?? '',
      partyName: map['partyName'] as String? ?? '',
      partyPhone: map['partyPhone'] as String? ?? '',
      type: TransactionType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => TransactionType.sale,
      ),
      paymentMode: PaymentMode.values.firstWhere(
        (e) => e.name == map['paymentMode'],
        orElse: () => PaymentMode.cash,
      ),
      cashAmount: (map['cashAmount'] as num?)?.toDouble() ?? 0.0,
      metalType: map['metalType'] as String? ?? '',
      metalWeight: (map['metalWeight'] as num?)?.toDouble() ?? 0.0,
      metalPurity: map['metalPurity'] as String? ?? '',
      notes: map['notes'] as String? ?? '',
      date: map['date'] != null ? TimeUtils.to2007(DateTime.parse(map['date']).toLocal()) : TimeUtils.now,
      createdAt: map['createdAt'] != null ? TimeUtils.to2007(DateTime.parse(map['createdAt']).toLocal()) : TimeUtils.now,
      createdBy: map['createdBy'] as String?,
      updatedBy: map['updatedBy'] as String?,
      updatedAt: map['updatedAt'] != null ? TimeUtils.to2007(DateTime.parse(map['updatedAt']).toLocal()) : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'partyId': partyId,
      'partyName': partyName,
      'partyPhone': partyPhone,
      'type': type.name,
      'paymentMode': paymentMode.name,
      'cashAmount': cashAmount,
      'metalType': metalType,
      'metalWeight': metalWeight,
      'metalPurity': metalPurity,
      'notes': notes,
      'date': date.toUtc().toIso8601String(),
      'createdAt': createdAt.toUtc().toIso8601String(),
      if (createdBy != null) 'createdBy': createdBy,
      if (updatedBy != null) 'updatedBy': updatedBy,
      if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
    };
  }

  String get typeLabel {
    final isCredit = type == TransactionType.receipt || type == TransactionType.metalIn;
    final suffix = isCredit ? 'In' : 'Out';

    if (metalType == 'gold') {
      return 'Gold $suffix';
    } else if (metalType == 'diamond') {
      return 'Diamond $suffix';
    } else if (metalType.isEmpty) {
      if (type == TransactionType.receipt || type == TransactionType.payment) {
        if (paymentMode == PaymentMode.cash) {
          return 'Cash $suffix';
        } else if (paymentMode == PaymentMode.upi) {
          return 'UPI $suffix';
        } else if (paymentMode == PaymentMode.rtgs) {
          return 'RTGS $suffix';
        } else if (paymentMode == PaymentMode.online) {
          return 'Online $suffix';
        }
      }
    }

    switch (type) {
      case TransactionType.sale: return 'Sale';
      case TransactionType.purchase: return 'Purchase';
      case TransactionType.payment: return 'Payment';
      case TransactionType.receipt: return 'Receipt';
      case TransactionType.metalIn: return 'Metal In';
      case TransactionType.metalOut: return 'Metal Out';
      case TransactionType.return_: return 'Return';
    }
  }
}
