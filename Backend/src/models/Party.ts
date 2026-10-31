import mongoose, { Schema, Document } from 'mongoose';

export interface IParty extends Document {
  name: string;
  type: string;
  phone: string;
  email: string;
  address: string;
  cashBalance: number;
  goldBalanceGrams: number;
  silverBalanceGrams: number;
  diamondBalanceCarats: number;
  openingCashBalance: number;
  openingGoldBalanceGrams: number;
  openingDiamondBalanceCarats: number;
  createdAt: Date;
  updatedAt: Date;
}

const PartySchema: Schema = new Schema({
  name: { type: String, required: true },
  type: { type: String, default: 'Other' },
  phone: { type: String, default: '' },
  email: { type: String, default: '' },
  address: { type: String, default: '' },
  cashBalance: { type: Number, default: 0 },
  goldBalanceGrams: { type: Number, default: 0 },
  silverBalanceGrams: { type: Number, default: 0 },
  diamondBalanceCarats: { type: Number, default: 0 },
  openingCashBalance: { type: Number, default: 0 },
  openingGoldBalanceGrams: { type: Number, default: 0 },
  openingDiamondBalanceCarats: { type: Number, default: 0 },
}, {
  timestamps: true
});

// Index for the primary sort query in GET /api/parties
PartySchema.index({ updatedAt: -1 });

export const Party = mongoose.model<IParty>('Party', PartySchema);
