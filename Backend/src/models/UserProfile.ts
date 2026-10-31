import { Schema, model } from 'mongoose';

export interface IUserProfile {
  name: string;
  mobile: string;
  status: 'inactive' | 'pending_approval' | 'approved';
  sessionActive: boolean;
  requestPending: boolean;
  requestedAt: Date | null;
  lastApprovalTime: Date | null;
  approvedBy: string | null;
  deviceInfo: {
    deviceModel: string;
    platform: string;
  };
  approvedDeviceId: string | null;
  approvedDeviceBrand: string | null;
  approvedDeviceModel: string | null;
  pendingDeviceId: string | null;
  pendingDeviceBrand: string | null;
  pendingDeviceModel: string | null;
  expiresAt: Date | null;
  createdAt?: Date;
  updatedAt?: Date;
}

const userProfileSchema = new Schema<IUserProfile>(
  {
    name: { type: String, required: true },
    mobile: { type: String, required: true },
    status: {
      type: String,
      enum: ['inactive', 'pending_approval', 'approved'],
      default: 'inactive',
    },
    sessionActive: { type: Boolean, default: false },
    requestPending: { type: Boolean, default: false },
    requestedAt: { type: Date, default: null },
    lastApprovalTime: { type: Date, default: null },
    approvedBy: { type: String, default: null },
    deviceInfo: {
      deviceModel: { type: String, default: '' },
      platform: { type: String, default: '' },
    },
    approvedDeviceId: { type: String, default: null },
    approvedDeviceBrand: { type: String, default: null },
    approvedDeviceModel: { type: String, default: null },
    pendingDeviceId: { type: String, default: null },
    pendingDeviceBrand: { type: String, default: null },
    pendingDeviceModel: { type: String, default: null },
    expiresAt: { type: Date, default: null },
  },
  {
    timestamps: true,
  }
);

// Index for device session authentication lookup in POST /api/verify-session
userProfileSchema.index({ approvedDeviceId: 1 });

export const UserProfile = model<IUserProfile>('UserProfile', userProfileSchema);
