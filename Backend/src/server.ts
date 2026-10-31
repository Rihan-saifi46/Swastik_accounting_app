import express, { Request, Response, NextFunction } from 'express';
import mongoose from 'mongoose';
import cors from 'cors';
import dotenv from 'dotenv';
import dns from 'dns';
import { Admin } from './models/Admin';
import { Party } from './models/Party';
import { Transaction } from './models/Transaction';
import { Reminder } from './models/Reminder';
import { Appointment } from './models/Appointment';
import { UserProfile } from './models/UserProfile';
import { DailyClosingBalance } from './models/DailyClosingBalance';
import {
  log,
  requestLogger,
  errorHandler,
  notFoundHandler,
  installProcessLogging,
  loggerConfig,
} from './logger';

// Force use of reliable public DNS to prevent SRV ETIMEOUT on some networks
dns.setServers(['8.8.8.8', '1.1.1.1']);

dotenv.config();

installProcessLogging();

const app = express();
const PORT = process.env.PORT || 5000;
const MONGO_URI = process.env.MONGO_URI || '';

app.use(cors());
app.use(express.json());
// Must come after express.json() so request bodies are parsed when logged.
app.use(requestLogger);

// Escape a user-supplied string so it can be safely used as an exact,
// case-insensitive regex match (prevents regex injection / ReDoS from headers).
function escapeRegex(input: string): string {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Staff sessions expire at the shop's daily closing time (IST). A session
// approved at/after closing lasts until the NEXT day's closing — no short
// evening window. Change SESSION_CLOSING_HOUR_IST to move the daily cutoff.
const SESSION_CLOSING_HOUR_IST = 21; // 9 PM IST

function computeSessionExpiry(now: Date = new Date()): Date {
  const istOffsetMs = 5.5 * 60 * 60 * 1000;
  const istNow = new Date(now.getTime() + istOffsetMs);
  const closingIST = new Date(istNow);
  closingIST.setUTCHours(SESSION_CLOSING_HOUR_IST, 0, 0, 0);
  // If we're already at/after today's closing time, roll to tomorrow's closing.
  if (istNow.getTime() >= closingIST.getTime()) {
    closingIST.setUTCDate(closingIST.getUTCDate() + 1);
  }
  // Convert the IST closing instant back to UTC for storage.
  return new Date(closingIST.getTime() - istOffsetMs);
}

// Server-Sent Events (SSE) clients
let sseClients: Response[] = [];

// Generic helper to push a named SSE event to every connected client.
function broadcastEvent(event: string) {
  log.debug('SSE', `Broadcasting '${event}' to ${sseClients.length} client(s)`);
  sseClients.forEach(client => {
    try {
      client.write(`event: ${event}\ndata: {}\n\n`);
    } catch (err) {
      log.error('SSE', `Failed to write '${event}' to a client`, err);
    }
  });
}

// Helper to broadcast profile updates
function broadcastProfilesUpdated() {
  broadcastEvent('profiles_updated');
}

// In-Memory/Local Admin records as fallback if MongoDB is not connected
let isMongoConnected = false;
let fallbackAdmins: any[] = [];

// In-Memory/Local UserProfile records as fallback if MongoDB is not connected
let fallbackUserProfiles: any[] = [
  {
    _id: '60d5ec4b86cd5d3a9c7b99c1',
    name: 'Shailendra',
    mobile: '9876543210',
    status: 'inactive',
    sessionActive: false,
    requestPending: false,
    requestedAt: null,
    lastApprovalTime: null,
    approvedBy: null,
    deviceInfo: {
      deviceModel: 'Pixel 6',
      platform: 'android'
    },
    approvedDeviceId: null,
    approvedDeviceBrand: null,
    approvedDeviceModel: null,
    pendingDeviceId: null,
    pendingDeviceBrand: null,
    pendingDeviceModel: null,
    expiresAt: null,
    createdAt: new Date(),
    updatedAt: new Date()
  }
];

// Connect to MongoDB
const mongoConnectStartedAt = Date.now();
log.info('MONGO', 'Connecting…', { uri: MONGO_URI ? MONGO_URI.replace(/\/\/[^@]*@/, '//***:***@') : '(MONGO_URI is empty!)' });
mongoose
  .connect(MONGO_URI)
  .then(async () => {
    log.info('MONGO', `Connected successfully in ${Date.now() - mongoConnectStartedAt}ms`, {
      db: mongoose.connection.name,
      host: mongoose.connection.host,
    });
    isMongoConnected = true;
    log.info('STARTUP', 'Admin seeding on startup is disabled.');
    seedUserProfile();
    await recalculateDailyBalances();
  })
  .catch((err) => {
    log.error('MONGO', 'Connection failed (bad credentials or network). Data routes will return 503 until MongoDB is reachable.', err);
    isMongoConnected = false;
  });

// Keep isMongoConnected accurate across mid-life disconnects/reconnects so the
// guard below flips to 503 (rather than serving stale/placeholder data) the
// moment the DB drops, and recovers automatically when it comes back.
mongoose.connection.on('disconnected', () => {
  isMongoConnected = false;
  log.warn('MONGO', 'Disconnected — data routes will return 503 until reconnected.');
});
mongoose.connection.on('reconnected', () => {
  isMongoConnected = true;
  log.info('MONGO', 'Reconnected — data routes restored.');
});
mongoose.connection.on('error', (err) => {
  log.error('MONGO', 'Driver-level connection error', err);
});

// Fail closed: while MongoDB is unavailable (startup window or a dropped
// connection), reject data requests with 503 so clients RETRY instead of
// receiving empty/placeholder data and treating it as "logged out / no data".
// Health and time stay open for monitoring and clock sync.
app.use((req: Request, res: Response, next: NextFunction) => {
  if (isMongoConnected) return next();
  if (req.path === '/api/health' || req.path === '/api/time') return next();
  log.warn('DB-GUARD', `503 ${req.method} ${req.path} — MongoDB not connected`, { id: req.requestId });
  return res.status(503).json({
    error: 'Service temporarily unavailable: database not connected. Please retry shortly.',
  });
});

// Seed default UserProfile if none exists
async function seedUserProfile() {
  try {
    if (!isMongoConnected) return;
    const profileCount = await UserProfile.countDocuments();
    if (profileCount === 0) {
      log.info('SEED', 'No user profiles found in database. Seeding default profile…');
      const defaultProfile = new UserProfile({
        name: 'Shailendra',
        mobile: '9876543210',
        status: 'inactive',
        sessionActive: false,
        requestPending: false,
        requestedAt: null,
        lastApprovalTime: null,
        approvedBy: null,
        deviceInfo: {
          deviceModel: '',
          platform: '',
        },
        approvedDeviceId: null,
        approvedDeviceBrand: null,
        approvedDeviceModel: null,
        pendingDeviceId: null,
        pendingDeviceBrand: null,
        pendingDeviceModel: null,
        expiresAt: null,
      });
      await defaultProfile.save();
      log.info('SEED', 'Default user profile seeded successfully', { id: defaultProfile._id, name: defaultProfile.name });
    }
  } catch (error) {
    log.error('SEED', 'Error seeding user profile', error);
  }
}

// Verification Endpoint
app.post('/api/verify', async (req: Request, res: Response) => {
  try {
    const { androidId, brand, model } = req.body;

    if (!androidId || !brand) {
      log.warn('VERIFY', 'Rejected: missing androidId or brand', { id: req.requestId, androidId, brand });
      return res.status(400).json({
        verified: false,
        message: 'Missing required parameters: androidId and brand',
      });
    }

    log.info('VERIFY', 'Verification request received', { id: req.requestId, brand, model, androidId });

    if (isMongoConnected) {
      // Check if any admins exist in MongoDB
      const adminCount = await Admin.countDocuments();
      if (adminCount === 0) {
        log.warn('VERIFY', 'No admins in database — registering this device as the admin', { androidId, brand, model });
        const newAdmin = new Admin({
          brand,
          model: model || 'Unknown Model',
          androidId,
        });
        await newAdmin.save();
        log.info('VERIFY', 'First admin registered successfully', { id: newAdmin._id, brand, model, androidId });
        return res.json({ verified: true, admin: newAdmin });
      }

      // Query database for matching brand and androidId (case-insensitive for brand)
      const matchingAdmin = await Admin.findOne({
        androidId: { $regex: new RegExp(`^${escapeRegex(androidId)}$`, 'i') },
        brand: { $regex: new RegExp(`^${escapeRegex(brand)}$`, 'i') },
      });

      if (matchingAdmin) {
        log.info('VERIFY', 'Success (MongoDB): admin match found', { id: req.requestId, adminId: matchingAdmin._id, androidId });
        return res.json({ verified: true, admin: matchingAdmin });
      }
    } else {
      // In-memory fallback
      if (fallbackAdmins.length === 0) {
        log.warn('VERIFY', 'No admins in-memory — registering this device as the admin', { androidId, brand, model });
        const newAdmin = {
          brand,
          model: model || 'Unknown Model',
          androidId,
        };
        fallbackAdmins.push(newAdmin);
        log.info('VERIFY', 'First fallback admin registered successfully', newAdmin);
        return res.json({ verified: true, admin: newAdmin });
      }

      // Query local fallback memory database
      const match = fallbackAdmins.find(
        (admin) =>
          admin.androidId.toLowerCase() === androidId.toLowerCase() &&
          admin.brand.toLowerCase() === brand.toLowerCase()
      );

      if (match) {
        log.info('VERIFY', 'Success (in-memory fallback): match found', { id: req.requestId, androidId });
        return res.json({ verified: true, admin: match });
      }
    }

    log.warn('VERIFY', 'FAILED: device not authorized (no matching admin)', { id: req.requestId, brand, model, androidId });
    return res.json({
      verified: false,
      message: 'Device not authorized. Please contact to admin.',
    });
  } catch (error: any) {
    log.error('VERIFY', 'Error in POST /api/verify', error, { id: req.requestId, body: req.body });
    return res.status(500).json({
      verified: false,
      message: 'Server error during verification.',
    });
  }
});

// Device Management Endpoints
app.get('/api/devices', async (req: Request, res: Response) => {
  try {
    const now = new Date();
    
    // Auto-expire sessions
    if (isMongoConnected) {
      await UserProfile.updateMany(
        { sessionActive: true, expiresAt: { $lt: now } },
        { sessionActive: false, status: 'inactive' }
      );
    } else {
      fallbackUserProfiles.forEach(p => {
        if (p.sessionActive && p.expiresAt && now.getTime() > p.expiresAt.getTime()) {
          p.sessionActive = false;
          p.status = 'inactive';
          p.updatedAt = new Date();
        }
      });
    }

    const activeProfiles: any[] = [];
    if (isMongoConnected) {
      const profiles = await UserProfile.find({ sessionActive: true });
      profiles.forEach(profile => {
        activeProfiles.push({
          id: profile._id.toString(),
          userName: profile.name,
          phoneNumber: profile.mobile,
          brand: profile.approvedDeviceBrand || (profile.deviceInfo.platform === 'android' ? 'Android' : (profile.deviceInfo.platform === 'ios' ? 'iOS' : 'Device')),
          model: profile.approvedDeviceModel || profile.deviceInfo.deviceModel || 'Staff Device',
          androidId: profile.approvedDeviceId || `profile_${profile._id.toString()}`,
          lastActive: profile.lastApprovalTime 
            ? `Active since ${new Date(profile.lastApprovalTime).toLocaleTimeString()}`
            : 'Active Now'
        });
      });
    } else {
      fallbackUserProfiles.forEach(profile => {
        if (profile.sessionActive) {
          activeProfiles.push({
            id: profile._id,
            userName: profile.name,
            phoneNumber: profile.mobile,
            brand: profile.approvedDeviceBrand || (profile.deviceInfo.platform === 'android' ? 'Android' : (profile.deviceInfo.platform === 'ios' ? 'iOS' : 'Device')),
            model: profile.approvedDeviceModel || profile.deviceInfo.deviceModel || 'Staff Device',
            androidId: profile.approvedDeviceId || `profile_${profile._id}`,
            lastActive: profile.lastApprovalTime 
              ? `Active since ${new Date(profile.lastApprovalTime).toLocaleTimeString()}`
              : 'Active Now'
          });
        }
      });
    }
    const allSessions = [...activeProfiles];
    log.debug('DEVICES', `Returning ${allSessions.length} active session(s)`, { id: req.requestId });
    res.json(allSessions);
  } catch (error: any) {
    log.error('DEVICES', 'Error in GET /api/devices', error, { id: req.requestId });
    res.status(500).json({ error: 'Server error retrieving device sessions.' });
  }
});

app.delete('/api/devices/:id', async (req: Request, res: Response) => {
  try {
    const { id } = req.params;

    // Check if it matches a UserProfile ID
    if (isMongoConnected) {
      const profile = await UserProfile.findById(id);
      if (profile) {
        profile.sessionActive = false;
        profile.status = 'inactive';
        profile.requestPending = false;
        profile.approvedDeviceId = null;
        profile.approvedDeviceBrand = null;
        profile.approvedDeviceModel = null;
        profile.expiresAt = null;
        profile.lastApprovalTime = null;
        await profile.save();
        log.info('DEVICES', `Deauthorized UserProfile session remotely`, { id: req.requestId, profileId: id, name: profile.name });
        return res.json({ success: true, message: 'User profile session terminated successfully.' });
      }
    } else {
      const profile = fallbackUserProfiles.find((p) => p._id === id);
      if (profile) {
        profile.sessionActive = false;
        profile.status = 'inactive';
        profile.requestPending = false;
        profile.approvedDeviceId = null;
        profile.approvedDeviceBrand = null;
        profile.approvedDeviceModel = null;
        profile.expiresAt = null;
        profile.lastApprovalTime = null;
        profile.updatedAt = new Date();
        log.info('DEVICES', 'Deauthorized fallback UserProfile session remotely', { id: req.requestId, profileId: id, name: profile.name });
        return res.json({ success: true, message: 'User profile session terminated successfully.' });
      }
    }

    // Also deauthorize/delete from Admin collection to trigger real logout on that device if id matches an admin
    if (isMongoConnected) {
      const deletedAdmin = await Admin.findOneAndDelete({
        androidId: { $regex: new RegExp(`^${escapeRegex(id)}$`, 'i') },
      });
      if (deletedAdmin) {
         log.warn('DEVICES', 'Deauthorized ADMIN device via session deletion', { id: req.requestId, androidId: id, brand: deletedAdmin.brand, model: deletedAdmin.model });
         return res.json({ success: true, message: 'Admin device logged out successfully.' });
      }
    } else {
      const initialLength = fallbackAdmins.length;
      fallbackAdmins = fallbackAdmins.filter(
        (admin) => admin.androidId.toLowerCase() !== id.toLowerCase()
      );
      if (initialLength > fallbackAdmins.length) {
         log.warn('DEVICES', 'Deauthorized fallback ADMIN device via session deletion', { id: req.requestId, androidId: id });
         return res.json({ success: true, message: 'Admin device logged out successfully.' });
      }
    }

    log.warn('DEVICES', 'Device session not found for deletion', { id: req.requestId, target: req.params.id });
    return res.status(404).json({ error: 'Device session not found.' });
  } catch (error: any) {
    log.error('DEVICES', 'Error in DELETE /api/devices/:id', error, { id: req.requestId, target: req.params.id });
    res.status(500).json({ error: 'Server error deleting device session.' });
  }
});

// CRUD/API endpoints for User Profiles
app.get('/api/user-profiles', async (req: Request, res: Response) => {
  try {
    const fiveMinutesAgo = new Date(Date.now() - 300000);
    if (isMongoConnected) {
      // Proactively clean up expired requests and expired sessions in DB
      const now = new Date();
      await UserProfile.updateMany(
        {
          status: 'pending_approval',
          requestedAt: { $lt: fiveMinutesAgo }
        },
        {
          status: 'inactive',
          requestPending: false
        }
      );
      await UserProfile.updateMany(
        { sessionActive: true, expiresAt: { $lt: now } },
        { sessionActive: false, status: 'inactive' }
      );
      const profiles = await UserProfile.find().sort({ createdAt: -1 });
      res.json(profiles);
    } else {
      // Proactively clean up expired requests in fallback memory
      const now = Date.now();
      fallbackUserProfiles.forEach((p) => {
        if (p.status === 'pending_approval' && p.requestedAt) {
          const requestedTime = new Date(p.requestedAt).getTime();
          if (now - requestedTime > 300000) {
            p.status = 'inactive';
            p.requestPending = false;
            p.updatedAt = new Date();
          }
        }
      });
      res.json(fallbackUserProfiles);
    }
  } catch (err: any) {
    log.error('PROFILES', 'Error in GET /api/user-profiles', err, { id: req.requestId });
    res.status(500).json({ error: err.message });
  }
});

// Staff session verification endpoint
app.post('/api/user-profiles/verify-session', async (req: Request, res: Response) => {
  try {
    const { androidId } = req.body;
    if (!androidId) {
      log.warn('SESSION', 'verify-session rejected: missing androidId', { id: req.requestId });
      return res.status(400).json({ valid: false, message: 'Missing androidId' });
    }

    const now = new Date();

    if (isMongoConnected) {
      const profile = await UserProfile.findOne({
        approvedDeviceId: androidId,
        status: 'approved',
        sessionActive: true,
        expiresAt: { $gt: now },
      });

      if (profile) {
        log.info('SESSION', 'Valid session found', { id: req.requestId, androidId, user: profile.name, expiresAt: profile.expiresAt });
        return res.json({ valid: true, profile });
      }
    } else {
      const profile = fallbackUserProfiles.find(
        (p) =>
          p.approvedDeviceId === androidId &&
          p.status === 'approved' &&
          p.sessionActive &&
          p.expiresAt &&
          new Date(p.expiresAt).getTime() > now.getTime()
      );

      if (profile) {
        log.info('SESSION', 'Valid fallback session found', { id: req.requestId, androidId, user: profile.name });
        return res.json({ valid: true, profile });
      }
    }

    log.warn('SESSION', 'No valid session for device — client will be logged out', { id: req.requestId, androidId });
    return res.json({ valid: false });
  } catch (err: any) {
    log.error('SESSION', 'Error in POST /api/user-profiles/verify-session', err, { id: req.requestId });
    return res.status(500).json({ valid: false, message: 'Server error' });
  }
});

app.post('/api/user-profiles', async (req: Request, res: Response) => {
  try {
    const { name, mobile, deviceInfo } = req.body;
    if (!name || !mobile) {
      log.warn('PROFILES', 'Create rejected: name and mobile are required', { id: req.requestId, name, mobile });
      return res.status(400).json({ error: 'Name and mobile number are required.' });
    }

    if (isMongoConnected) {
      const newProfile = new UserProfile({
        name,
        mobile,
        status: 'inactive',
        sessionActive: false,
        requestPending: false,
        requestedAt: null,
        lastApprovalTime: null,
        approvedBy: null,
        deviceInfo: {
          deviceModel: deviceInfo?.deviceModel || '',
          platform: deviceInfo?.platform || '',
        },
        approvedDeviceId: null,
        approvedDeviceBrand: null,
        approvedDeviceModel: null,
        pendingDeviceId: null,
        pendingDeviceBrand: null,
        pendingDeviceModel: null,
        expiresAt: null,
      });
      const savedProfile = await newProfile.save();
      log.info('PROFILES', 'Created user profile', { id: req.requestId, profileId: savedProfile._id, name, mobile });
      res.status(201).json(savedProfile);
    } else {
      const newProfile = {
        _id: `mock_profile_${Date.now()}`,
        name,
        mobile,
        status: 'inactive',
        sessionActive: false,
        requestPending: false,
        requestedAt: null,
        lastApprovalTime: null,
        approvedBy: null,
        deviceInfo: {
          deviceModel: deviceInfo?.deviceModel || '',
          platform: deviceInfo?.platform || '',
        },
        approvedDeviceId: null,
        approvedDeviceBrand: null,
        approvedDeviceModel: null,
        pendingDeviceId: null,
        pendingDeviceBrand: null,
        pendingDeviceModel: null,
        expiresAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      };
      fallbackUserProfiles.push(newProfile);
      log.info('PROFILES', 'Created fallback user profile', { id: req.requestId, profileId: newProfile._id, name, mobile });
      res.status(201).json(newProfile);
    }
  } catch (err: any) {
    log.error('PROFILES', 'Error in POST /api/user-profiles', err, { id: req.requestId });
    res.status(400).json({ error: err.message });
  }
});

app.post('/api/user-profiles/:id/request-access', async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    const { deviceInfo, androidId, brand, model: deviceModel } = req.body;
    log.info('ACCESS', 'Access requested', { id: req.requestId, profileId: id, androidId, brand, model: deviceModel });

    if (isMongoConnected) {
      const profile = await UserProfile.findById(id);
      if (!profile) {
        log.warn('ACCESS', 'Access request for unknown profile', { id: req.requestId, profileId: id });
        return res.status(404).json({ error: 'User profile not found.' });
      }

      profile.status = 'pending_approval';
      profile.requestPending = true;
      profile.requestedAt = new Date();
      if (deviceInfo) {
        profile.deviceInfo = {
          deviceModel: deviceInfo.deviceModel || '',
          platform: deviceInfo.platform || '',
        };
      }
      profile.pendingDeviceId = androidId || null;
      profile.pendingDeviceBrand = brand || null;
      profile.pendingDeviceModel = deviceModel || null;
      const updated = await profile.save();

      // Set 5min timer to revert status to inactive
      setTimeout(async () => {
        try {
          const currentProfile = await UserProfile.findById(id);
          if (currentProfile && currentProfile.status === 'pending_approval') {
            currentProfile.status = 'inactive';
            currentProfile.requestPending = false;
            await currentProfile.save();
            log.info('ACCESS', `Request expired — profile ${currentProfile.name} (DB) reverted to inactive`, { profileId: id });
          }
        } catch (timeoutErr) {
          log.error('ACCESS', 'Expiry timer failed', timeoutErr, { profileId: id });
        }
      }, 300000);

      res.json(updated);
      broadcastProfilesUpdated();
    } else {
      const profile = fallbackUserProfiles.find((p) => p._id === id);
      if (!profile) {
        log.warn('ACCESS', 'Access request for unknown fallback profile', { id: req.requestId, profileId: id });
        return res.status(404).json({ error: 'User profile not found.' });
      }

      profile.status = 'pending_approval';
      profile.requestPending = true;
      profile.requestedAt = new Date();
      if (deviceInfo) {
        profile.deviceInfo = {
          deviceModel: deviceInfo.deviceModel || '',
          platform: deviceInfo.platform || '',
        };
      }
      profile.pendingDeviceId = androidId || null;
      profile.pendingDeviceBrand = brand || null;
      profile.pendingDeviceModel = deviceModel || null;
      profile.updatedAt = new Date();

      // Set 5min timer to revert status to inactive
      setTimeout(() => {
        if (profile.status === 'pending_approval') {
          profile.status = 'inactive';
          profile.requestPending = false;
          profile.updatedAt = new Date();
          log.info('ACCESS', `Request expired — profile ${profile.name} (in-memory) reverted to inactive`, { profileId: id });
        }
      }, 300000);

      res.json(profile);
      broadcastProfilesUpdated();
    }
  } catch (err: any) {
    log.error('ACCESS', 'Error in POST /api/user-profiles/:id/request-access', err, { id: req.requestId, profileId: req.params.id });
    res.status(400).json({ error: err.message });
  }
});

app.post('/api/user-profiles/:id/approve', async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    if (isMongoConnected) {
      const profile = await UserProfile.findById(id);
      if (!profile) {
        log.warn('APPROVE', 'Approve for unknown profile', { id: req.requestId, profileId: id });
        return res.status(404).json({ error: 'User profile not found.' });
      }
      profile.status = 'approved';
      profile.sessionActive = true;
      profile.requestPending = false;
      profile.lastApprovalTime = new Date();
      profile.approvedBy = 'Admin';
      profile.approvedDeviceId = profile.pendingDeviceId;
      profile.approvedDeviceBrand = profile.pendingDeviceBrand;
      profile.approvedDeviceModel = profile.pendingDeviceModel;
      profile.pendingDeviceId = null;
      profile.pendingDeviceBrand = null;
      profile.pendingDeviceModel = null;

      // Session expires at the shop's daily closing time (see computeSessionExpiry).
      const expiresAt = computeSessionExpiry(new Date());
      profile.expiresAt = expiresAt;

      const updated = await profile.save();
      log.info('APPROVE', `Profile ${profile.name} (DB) approved by Admin`, {
        id: req.requestId, profileId: id, deviceId: profile.approvedDeviceId, expiresAt,
      });
      res.json(updated);
      broadcastProfilesUpdated();
    } else {
      const profile = fallbackUserProfiles.find((p) => p._id === id);
      if (!profile) {
        log.warn('APPROVE', 'Approve for unknown fallback profile', { id: req.requestId, profileId: id });
        return res.status(404).json({ error: 'User profile not found.' });
      }
      profile.status = 'approved';
      profile.sessionActive = true;
      profile.requestPending = false;
      profile.lastApprovalTime = new Date();
      profile.approvedBy = 'Admin';
      profile.approvedDeviceId = profile.pendingDeviceId;
      profile.approvedDeviceBrand = profile.pendingDeviceBrand;
      profile.approvedDeviceModel = profile.pendingDeviceModel;
      profile.pendingDeviceId = null;
      profile.pendingDeviceBrand = null;
      profile.pendingDeviceModel = null;

      // Session expires at the shop's daily closing time (see computeSessionExpiry).
      const expiresAt = computeSessionExpiry(new Date());
      profile.expiresAt = expiresAt;

      profile.updatedAt = new Date();
      log.info('APPROVE', `Profile ${profile.name} (in-memory) approved by Admin`, { id: req.requestId, profileId: id, expiresAt });
      res.json(profile);
      broadcastProfilesUpdated();
    }
  } catch (err: any) {
    log.error('APPROVE', 'Error in POST /api/user-profiles/:id/approve', err, { id: req.requestId, profileId: req.params.id });
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/user-profiles/:id/decline', async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    if (isMongoConnected) {
      const profile = await UserProfile.findById(id);
      if (!profile) {
        return res.status(404).json({ error: 'User profile not found.' });
      }
      profile.status = 'inactive';
      profile.sessionActive = false;
      profile.requestPending = false;
      profile.requestedAt = null;
      profile.pendingDeviceId = null;
      profile.pendingDeviceBrand = null;
      profile.pendingDeviceModel = null;
      const updated = await profile.save();
      log.info('DECLINE', `Profile ${profile.name} (DB) declined by Admin`, { id: req.requestId, profileId: id });
      res.json(updated);
      broadcastProfilesUpdated();
    } else {
      const profile = fallbackUserProfiles.find((p) => p._id === id);
      if (!profile) {
        return res.status(404).json({ error: 'User profile not found.' });
      }
      profile.status = 'inactive';
      profile.sessionActive = false;
      profile.requestPending = false;
      profile.requestedAt = null;
      profile.pendingDeviceId = null;
      profile.pendingDeviceBrand = null;
      profile.pendingDeviceModel = null;
      profile.updatedAt = new Date();
      log.info('DECLINE', `Profile ${profile.name} (in-memory) declined by Admin`, { id: req.requestId, profileId: id });
      res.json(profile);
      broadcastProfilesUpdated();
    }
  } catch (err: any) {
    log.error('DECLINE', 'Error in POST /api/user-profiles/:id/decline', err, { id: req.requestId, profileId: req.params.id });
    res.status(500).json({ error: err.message });
  }
});

// Fallback for daily closing balances when MongoDB is not connected
let fallbackDailyClosingBalances: any[] = [];

// Helper to convert date to IST date string YYYY-MM-DD
function getISTDateString(date: Date): string {
  const utcMs = date.getTime();
  const istOffsetMs = 5.5 * 60 * 60 * 1000;
  const istDate = new Date(utcMs + istOffsetMs);
  const yyyy = istDate.getUTCFullYear();
  const mm = String(istDate.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(istDate.getUTCDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

// Recalculates closing balances — incrementally when a fromDate is given,
// or fully when called without arguments (e.g. from the GET endpoint).
export async function recalculateDailyBalances(fromDate?: Date): Promise<void> {
  const recalcStartedAt = Date.now();
  try {
    if (!isMongoConnected) {
      log.warn('BALANCES', 'Skipping recalculation — MongoDB not connected.');
      return;
    }
    log.debug('BALANCES', `Recalculation started (${fromDate ? `incremental from ${fromDate.toISOString()}` : 'full'})`);

    // 1. Determine the start date and seed balances
    let startDateStr: string;
    let runningCash = 0;
    let runningOnline = 0;
    let runningGold = 0;
    let runningDiamond = 0;

    if (fromDate) {
      // Incremental mode: start from the given date
      startDateStr = getISTDateString(fromDate);

      // Seed from the previous day's closing balance (if it exists)
      const startIST = new Date(fromDate.getTime() + 5.5 * 60 * 60 * 1000);
      startIST.setUTCHours(0, 0, 0, 0);
      const prevDayIST = new Date(startIST.getTime() - 24 * 60 * 60 * 1000);
      const prevDateStr = `${prevDayIST.getUTCFullYear()}-${String(prevDayIST.getUTCMonth() + 1).padStart(2, '0')}-${String(prevDayIST.getUTCDate()).padStart(2, '0')}`;

      const prevBalance = await DailyClosingBalance.findOne({ date: prevDateStr });
      if (prevBalance) {
        runningCash = prevBalance.closingCash;
        runningOnline = prevBalance.closingOnline;
        runningGold = prevBalance.closingGold;
        runningDiamond = prevBalance.closingDiamond;
      } else {
        // No previous balance — sum all transactions before this date
        const txsBefore = await Transaction.find({ date: { $lt: fromDate } }).sort({ date: 1 });
        for (const tx of txsBefore) {
          const isCredit = tx.type === 'receipt' || tx.type === 'metalIn';
          const isDebit = tx.type === 'payment' || tx.type === 'metalOut';
          const val = tx.metalType ? tx.metalWeight : tx.cashAmount;

          if (!tx.metalType) {
            if (tx.paymentMode === 'cash') {
              if (isCredit) runningCash += val;
              if (isDebit) runningCash -= val;
            } else if (tx.paymentMode === 'online' || tx.paymentMode === 'upi' || tx.paymentMode === 'rtgs') {
              if (isCredit) runningOnline += val;
              if (isDebit) runningOnline -= val;
            }
          } else if (tx.metalType === 'gold') {
            if (isCredit) runningGold += val;
            if (isDebit) runningGold -= val;
          } else if (tx.metalType === 'diamond') {
            if (isCredit) runningDiamond += val;
            if (isDebit) runningDiamond -= val;
          }
        }
      }
    } else {
      // Full recalculation mode
      const transactions = await Transaction.find().sort({ date: 1 });
      if (transactions.length === 0) {
        await DailyClosingBalance.deleteMany({});
        log.info('BALANCES', 'No transactions — cleared all daily closing balances.');
        return;
      }
      await DailyClosingBalance.deleteMany({});
      startDateStr = getISTDateString(transactions[0].date);
    }

    // 2. Get all transactions from the start date onwards
    const istOffset = 5.5 * 60 * 60 * 1000;
    const [yyyy, mm, dd] = startDateStr.split('-').map(Number);
    // Convert the IST start-of-day back to UTC for the query
    const startUTC = new Date(Date.UTC(yyyy, mm - 1, dd) - istOffset);

    const txsFromStart = await Transaction.find({ date: { $gte: startUTC } }).sort({ date: 1 });

    // Group transactions by IST date
    const txByDate: { [dateStr: string]: any[] } = {};
    for (const tx of txsFromStart) {
      const dStr = getISTDateString(tx.date);
      if (!txByDate[dStr]) txByDate[dStr] = [];
      txByDate[dStr].push(tx);
    }

    // 3. Determine the latest relevant transaction date across the dataset
    let latestTxDate: Date | null = null;
    if (txsFromStart.length > 0) {
      latestTxDate = txsFromStart[txsFromStart.length - 1].date;
    } else {
      const latestOverallTx = await Transaction.findOne().sort({ date: -1 }).lean();
      latestTxDate = latestOverallTx ? latestOverallTx.date : null;
    }

    if (!latestTxDate) {
      // No transactions exist anywhere in the database — clear closing balances
      await DailyClosingBalance.deleteMany({});
      log.info('BALANCES', 'No transactions remaining in database — cleared all daily closing balances.');
      return;
    }

    const lastISTStr = getISTDateString(latestTxDate);
    // Remove any orphaned closing balance rows that exist past the latest transaction date
    await DailyClosingBalance.deleteMany({ date: { $gt: lastISTStr } });

    // If the recalculation starting day is already past the latest transaction date,
    // future orphaned records were pruned above; nothing more to calculate.
    if (startDateStr > lastISTStr) {
      log.info('BALANCES', `Recalculation start date ${startDateStr} is past latest transaction ${lastISTStr}. Cleaned future records.`);
      return;
    }

    const current = new Date(Date.UTC(yyyy, mm - 1, dd));
    const [endY, endM, endD] = lastISTStr.split('-').map(Number);
    const end = new Date(Date.UTC(endY, endM - 1, endD));

    while (current.getTime() <= end.getTime()) {
      const cyyyy = current.getUTCFullYear();
      const cmm = String(current.getUTCMonth() + 1).padStart(2, '0');
      const cdd = String(current.getUTCDate()).padStart(2, '0');
      const dateStr = `${cyyyy}-${cmm}-${cdd}`;

      const dayTxs = txByDate[dateStr] || [];
      for (const tx of dayTxs) {
        const isCredit = tx.type === 'receipt' || tx.type === 'metalIn';
        const isDebit = tx.type === 'payment' || tx.type === 'metalOut';
        const val = tx.metalType ? tx.metalWeight : tx.cashAmount;

        if (!tx.metalType) {
          if (tx.paymentMode === 'cash') {
            if (isCredit) runningCash += val;
            if (isDebit) runningCash -= val;
          } else if (tx.paymentMode === 'online' || tx.paymentMode === 'upi' || tx.paymentMode === 'rtgs') {
            if (isCredit) runningOnline += val;
            if (isDebit) runningOnline -= val;
          }
        } else if (tx.metalType === 'gold') {
          if (isCredit) runningGold += val;
          if (isDebit) runningGold -= val;
        } else if (tx.metalType === 'diamond') {
          if (isCredit) runningDiamond += val;
          if (isDebit) runningDiamond -= val;
        }
      }

      await DailyClosingBalance.findOneAndUpdate(
        { date: dateStr },
        {
          date: dateStr,
          closingCash: runningCash,
          closingOnline: runningOnline,
          closingGold: runningGold,
          closingDiamond: runningDiamond,
        },
        { upsert: true, new: true }
      );

      current.setUTCDate(current.getUTCDate() + 1);
    }

    log.info('BALANCES', `Recalculation completed${fromDate ? ` (incremental from ${startDateStr})` : ' (full)'} in ${Date.now() - recalcStartedAt}ms`, {
      txsProcessed: txsFromStart.length,
      closing: { cash: runningCash, online: runningOnline, gold: runningGold, diamond: runningDiamond },
    });
  } catch (error) {
    log.error('BALANCES', `Recalculation FAILED after ${Date.now() - recalcStartedAt}ms`, error, {
      fromDate: fromDate?.toISOString(),
    });
  }
}

// GET endpoint to retrieve daily closing balances.
// Read-only: the collection is kept correct incrementally on every transaction
// write (see recalculateDailyBalances(savedTx.date) in the transaction routes),
// so there is no need to recompute the whole collection on every read.
app.get('/api/daily-balances', async (req, res) => {
  try {
    if (isMongoConnected) {
      const balances = await DailyClosingBalance.find().sort({ date: 1 }).lean();
      res.json(balances);
    } else {
      res.json(fallbackDailyClosingBalances);
    }
  } catch (err: any) {
    log.error('BALANCES', 'Error in GET /api/daily-balances', err, { id: req.requestId });
    res.status(500).json({ error: err.message });
  }
});

// Returns just the newest closing-balance row (the current running totals for
// cash / online / gold / diamond). The home summary cards poll this instead of
// downloading the entire day-by-day balance history to read one row.
app.get('/api/daily-balances/latest', async (req, res) => {
  try {
    if (isMongoConnected) {
      const latest = await DailyClosingBalance.findOne().sort({ date: -1 }).lean();
      res.json(latest || null);
    } else {
      const list = fallbackDailyClosingBalances;
      res.json(list.length ? list[list.length - 1] : null);
    }
  } catch (err: any) {
    log.error('BALANCES', 'Error in GET /api/daily-balances/latest', err, { id: req.requestId });
    res.status(500).json({ error: err.message });
  }
});

// CRUD Routes for Parties
app.get('/api/parties', async (req, res) => {
  try {
    const parties = await Party.find().sort({ updatedAt: -1 }).lean();
    log.debug('PARTIES', `Returning ${parties.length} parties`, { id: req.requestId });
    res.json(parties);
  } catch (err: any) {
    log.error('PARTIES', 'Error in GET /api/parties', err, { id: req.requestId });
    res.status(500).json({ error: err.message });
  }
});
app.post('/api/parties', async (req, res) => {
  try {
    const newParty = new Party(req.body);
    const savedParty = await newParty.save();
    log.info('PARTIES', 'Created party', { id: req.requestId, partyId: savedParty._id, name: savedParty.name });
    broadcastEvent('parties_updated');
    res.status(201).json(savedParty);
  } catch (err: any) {
    log.error('PARTIES', 'Error in POST /api/parties', err, { id: req.requestId, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.put('/api/parties/:id', async (req, res) => {
  try {
    const updatedParty = await Party.findByIdAndUpdate(req.params.id, req.body, { new: true });
    if (!updatedParty) log.warn('PARTIES', 'Update matched no party', { id: req.requestId, partyId: req.params.id });
    else log.info('PARTIES', 'Updated party', { id: req.requestId, partyId: req.params.id, name: updatedParty.name });
    broadcastEvent('parties_updated');
    res.json(updatedParty);
  } catch (err: any) {
    log.error('PARTIES', 'Error in PUT /api/parties/:id', err, { id: req.requestId, partyId: req.params.id, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.delete('/api/parties/:id', async (req, res) => {
  try {
    await Party.findByIdAndDelete(req.params.id);
    log.warn('PARTIES', 'Deleted party', { id: req.requestId, partyId: req.params.id });
    broadcastEvent('parties_updated');
    res.json({ message: 'Party deleted successfully' });
  } catch (err: any) {
    log.error('PARTIES', 'Error in DELETE /api/parties/:id', err, { id: req.requestId, partyId: req.params.id });
    res.status(500).json({ error: err.message });
  }
});

// Authentication & Authorization Middlewares
async function authenticate(req: Request, res: Response, next: NextFunction) {
  try {
    const androidId = req.headers['x-android-id'] as string;
    const brand = req.headers['x-device-brand'] as string;
    const staffId = req.headers['x-staff-id'] as string;

    // Check if it matches an Admin
    if (androidId && brand) {
      if (isMongoConnected) {
        const admin = await Admin.findOne({
          androidId: { $regex: new RegExp(`^${escapeRegex(androidId)}$`, 'i') },
          brand: { $regex: new RegExp(`^${escapeRegex(brand)}$`, 'i') },
        });
        if (admin) {
          req.body.callerRole = 'admin';
          log.debug('AUTH', 'Authenticated as admin', { id: req.requestId, androidId });
          return next();
        }
      } else {
        const admin = fallbackAdmins.find(
          (a) =>
            a.androidId.toLowerCase() === androidId.toLowerCase() &&
            a.brand.toLowerCase() === brand.toLowerCase()
        );
        if (admin) {
          req.body.callerRole = 'admin';
          log.debug('AUTH', 'Authenticated as admin (fallback)', { id: req.requestId, androidId });
          return next();
        }
      }
    }

    // Check if it matches an approved active Staff Profile
    if (staffId) {
      if (isMongoConnected) {
        const profile = await UserProfile.findById(staffId);
        if (profile && profile.sessionActive && profile.status === 'approved') {
          // Validate device matches approved device
          if (profile.approvedDeviceId && androidId && profile.approvedDeviceId.toLowerCase() !== androidId.toLowerCase()) {
            log.warn('AUTH', 'DENIED: device mismatch — session is bound to a different device', {
              id: req.requestId, staffId, name: profile.name, approvedDeviceId: profile.approvedDeviceId, presentedDeviceId: androidId,
            });
            return res.status(401).json({ error: 'Unauthorized: Device mismatch. This session is bound to a different device.' });
          }
          req.body.callerRole = 'staff';
          log.debug('AUTH', 'Authenticated as staff', { id: req.requestId, staffId, name: profile.name });
          return next();
        }
        if (profile) {
          log.warn('AUTH', 'DENIED: staff profile is not an active approved session', {
            id: req.requestId, staffId, name: profile.name, status: profile.status, sessionActive: profile.sessionActive,
          });
        } else {
          log.warn('AUTH', 'DENIED: staff profile not found', { id: req.requestId, staffId });
        }
      } else {
        const profile = fallbackUserProfiles.find(
          (p) => p._id === staffId && p.sessionActive && p.status === 'approved'
        );
        if (profile) {
          // Validate device matches approved device
          if (profile.approvedDeviceId && androidId && profile.approvedDeviceId.toLowerCase() !== androidId.toLowerCase()) {
            log.warn('AUTH', 'DENIED: device mismatch (fallback)', {
              id: req.requestId, staffId, approvedDeviceId: profile.approvedDeviceId, presentedDeviceId: androidId,
            });
            return res.status(401).json({ error: 'Unauthorized: Device mismatch. This session is bound to a different device.' });
          }
          req.body.callerRole = 'staff';
          log.debug('AUTH', 'Authenticated as staff (fallback)', { id: req.requestId, staffId });
          return next();
        }
      }
    }

    log.warn('AUTH', `DENIED: 401 on ${req.method} ${req.originalUrl} — missing or invalid auth headers`, {
      id: req.requestId, androidId: androidId || null, brand: brand || null, staffId: staffId || null,
    });
    return res.status(401).json({ error: 'Unauthorized: Access denied. Missing or invalid authentication headers.' });
  } catch (err: any) {
    log.error('AUTH', 'Error while authenticating', err, { id: req.requestId });
    return res.status(500).json({ error: err.message });
  }
}

function requireAdmin(req: Request, res: Response, next: NextFunction) {
  if (req.body.callerRole === 'admin') {
    return next();
  }
  log.warn('AUTH', `DENIED: 403 on ${req.method} ${req.originalUrl} — admin required`, {
    id: req.requestId, callerRole: req.body.callerRole ?? 'none',
  });
  return res.status(403).json({ error: 'Forbidden: Only Admins can modify or delete finalized transactions.' });
}

// ─── Party balance engine (single source of truth, server-side) ──────────
// Computes the atomic $inc deltas a transaction applies to its party's stored
// balances. This mirrors the ledger convention the app uses:
//   debit  (payment / sale / metalOut)          increases the party's balance
//   credit (receipt / purchase / metalIn / return_) decreases it
// `direction` is +1 to apply a transaction, -1 to reverse it.
function partyBalanceInc(tx: any, direction = 1): Record<string, number> {
  const isDebit = tx.type === 'payment' || tx.type === 'sale' || tx.type === 'metalOut';
  const isCredit = tx.type === 'receipt' || tx.type === 'purchase' || tx.type === 'metalIn' || tx.type === 'return_';
  const sign = (isDebit ? 1 : isCredit ? -1 : 0) * direction;
  if (sign === 0) return {};

  if (!tx.metalType) {
    const amt = Number(tx.cashAmount) || 0;
    return amt ? { cashBalance: sign * amt } : {};
  }
  const wt = Number(tx.metalWeight) || 0;
  if (tx.metalType === 'gold') return wt ? { goldBalanceGrams: sign * wt } : {};
  if (tx.metalType === 'diamond') return wt ? { diamondBalanceCarats: sign * wt } : {};
  return {}; // silver / unknown metal types do not affect stored balances
}

function mergeInc(...incs: Record<string, number>[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const inc of incs) {
    for (const [k, v] of Object.entries(inc)) {
      out[k] = (out[k] || 0) + v;
    }
  }
  return out;
}

// Atomically apply an $inc to a party's balances. No-op when disconnected,
// when partyId is missing, or when there is nothing to change.
async function applyPartyBalanceInc(partyId: string, inc: Record<string, number>): Promise<void> {
  if (!isMongoConnected || !partyId) return;
  if (Object.keys(inc).length === 0) return;
  await Party.updateOne({ _id: partyId }, { $inc: inc });
}

// CRUD Routes for Transactions
//
// Supports optional server-side filtering and pagination so clients no longer
// have to download the entire collection on every poll:
//   ?partyId=<id>          → only that party's transactions (uses partyId index)
//   ?from=<iso>&to=<iso>   → only transactions in that date window (uses date index)
//   ?limit=<n>&skip=<n>    → return one batch of <n>, skipping <n> (infinite scroll)
// With no query params the behaviour is identical to before (full collection,
// newest first) — so existing callers keep working unchanged.
app.get('/api/transactions', authenticate, async (req, res) => {
  try {
    const { partyId, from, to, limit, skip } = req.query as Record<string, string | undefined>;

    const filter: Record<string, any> = {};
    if (partyId) filter.partyId = partyId;

    if (from || to) {
      const dateFilter: Record<string, Date> = {};
      const fromDate = from ? new Date(from) : undefined;
      const toDate = to ? new Date(to) : undefined;
      if (fromDate && !isNaN(fromDate.getTime())) dateFilter.$gte = fromDate;
      if (toDate && !isNaN(toDate.getTime())) dateFilter.$lte = toDate;
      if (Object.keys(dateFilter).length > 0) filter.date = dateFilter;
    }

    let query = Transaction.find(filter).sort({ date: -1 });

    const parsedSkip = Math.max(0, parseInt(skip ?? '', 10) || 0);
    const parsedLimit = parseInt(limit ?? '', 10);
    const paginated = Number.isFinite(parsedLimit) && parsedLimit > 0;
    if (paginated) {
      // Cap the page size so a bad/oversized request can't drag the server down.
      query = query.skip(parsedSkip).limit(Math.min(parsedLimit, 200));
    }

    // On the first page of a paginated request, report the total match count via
    // a header so the client can know whether more pages exist without a second
    // round-trip. Skipped on later pages to avoid a redundant count each scroll.
    if (paginated && parsedSkip === 0) {
      const total = await Transaction.countDocuments(filter);
      res.setHeader('X-Total-Count', String(total));
    }

    // .lean() returns plain JS objects instead of hydrated Mongoose documents —
    // noticeably less CPU/memory per request on these read-heavy list endpoints.
    const transactions = await query.lean();
    log.debug('TXN', `Returning ${transactions.length} transaction(s)`, {
      id: req.requestId, filter: { partyId, from, to }, paginated, limit: parsedLimit, skip: parsedSkip,
    });
    res.json(transactions);
  } catch (err: any) {
    log.error('TXN', 'Error in GET /api/transactions', err, { id: req.requestId, query: req.query });
    res.status(500).json({ error: err.message });
  }
});

// Running totals for the home summary cards, computed server-side with a single
// aggregation so the client no longer downloads the ENTIRE transactions
// collection every poll just to sum four numbers. The formula is kept byte-for
// -byte in step with the client's _computeCategoryTotal (home_screen.dart):
//   • cash    → non-metal txns paid in cash
//   • online  → non-metal txns paid online / upi / rtgs
//   • gold    → metalType == 'gold'   (weight)
//   • diamond → metalType == 'diamond'(weight)
// Credits (receipt / metalIn) add, debits (payment / metalOut) subtract.
// Optional ?from=<iso>&to=<iso> scopes the totals to a date window (all-time by
// default). Returns { cash, online, gold, diamond }.
app.get('/api/transactions/summary', authenticate, async (req, res) => {
  try {
    const { from, to } = req.query as Record<string, string | undefined>;

    const match: Record<string, any> = {};
    if (from || to) {
      const dateFilter: Record<string, Date> = {};
      const fromDate = from ? new Date(from) : undefined;
      const toDate = to ? new Date(to) : undefined;
      if (fromDate && !isNaN(fromDate.getTime())) dateFilter.$gte = fromDate;
      if (toDate && !isNaN(toDate.getTime())) dateFilter.$lte = toDate;
      if (Object.keys(dateFilter).length > 0) match.date = dateFilter;
    }

    if (!isMongoConnected) {
      log.warn('TXN', 'Summary requested while MongoDB is down — returning zeroes', { id: req.requestId });
      return res.json({ cash: 0, online: 0, gold: 0, diamond: 0 });
    }

    const pipeline: any[] = [];
    if (Object.keys(match).length > 0) pipeline.push({ $match: match });
    pipeline.push(
      {
        $addFields: {
          _mt: { $ifNull: ['$metalType', ''] },
          _sign: {
            $switch: {
              branches: [
                { case: { $in: ['$type', ['receipt', 'metalIn']] }, then: 1 },
                { case: { $in: ['$type', ['payment', 'metalOut']] }, then: -1 },
              ],
              default: 0,
            },
          },
        },
      },
      {
        $group: {
          _id: null,
          cash: {
            $sum: {
              $cond: [
                { $and: [{ $eq: ['$_mt', ''] }, { $eq: ['$paymentMode', 'cash'] }] },
                { $multiply: ['$_sign', { $ifNull: ['$cashAmount', 0] }] },
                0,
              ],
            },
          },
          online: {
            $sum: {
              $cond: [
                { $and: [{ $eq: ['$_mt', ''] }, { $in: ['$paymentMode', ['online', 'upi', 'rtgs']] }] },
                { $multiply: ['$_sign', { $ifNull: ['$cashAmount', 0] }] },
                0,
              ],
            },
          },
          gold: {
            $sum: {
              $cond: [
                { $eq: ['$_mt', 'gold'] },
                { $multiply: ['$_sign', { $ifNull: ['$metalWeight', 0] }] },
                0,
              ],
            },
          },
          diamond: {
            $sum: {
              $cond: [
                { $eq: ['$_mt', 'diamond'] },
                { $multiply: ['$_sign', { $ifNull: ['$metalWeight', 0] }] },
                0,
              ],
            },
          },
        },
      },
    );

    const [row] = await Transaction.aggregate(pipeline);
    const summary = {
      cash: row?.cash ?? 0,
      online: row?.online ?? 0,
      gold: row?.gold ?? 0,
      diamond: row?.diamond ?? 0,
    };
    log.debug('TXN', 'Summary computed', { id: req.requestId, window: { from, to }, summary });
    res.json(summary);
  } catch (err: any) {
    log.error('TXN', 'Error in GET /api/transactions/summary', err, { id: req.requestId, query: req.query });
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/transactions', authenticate, async (req, res) => {
  try {
    // Idempotency: check if an identical transaction was created in the last 60 seconds
    const sixtySecondsAgo = new Date(Date.now() - 60 * 1000);
    const duplicate = await Transaction.findOne({
      partyId: req.body.partyId,
      type: req.body.type,
      paymentMode: req.body.paymentMode,
      cashAmount: req.body.cashAmount,
      metalType: req.body.metalType,
      metalWeight: req.body.metalWeight,
      date: req.body.date,
      createdAt: { $gte: sixtySecondsAgo },
    });
    if (duplicate) {
      log.warn('TXN', 'Duplicate transaction detected within 60s — returning the existing one', {
        id: req.requestId, txId: duplicate._id, partyId: req.body.partyId, type: req.body.type,
      });
      return res.status(201).json(duplicate);
    }

    const newTx = new Transaction(req.body);
    const savedTx = await newTx.save();
    log.info('TXN', 'Created transaction', {
      id: req.requestId,
      txId: savedTx._id,
      partyId: savedTx.partyId,
      type: savedTx.type,
      paymentMode: savedTx.paymentMode,
      cashAmount: savedTx.cashAmount,
      metalType: savedTx.metalType,
      metalWeight: savedTx.metalWeight,
      date: savedTx.date,
      by: req.body.callerRole,
    });
    // Atomically apply this transaction's impact to the party balance (server is
    // the single authority — the client no longer read-modify-writes balances).
    try {
      const inc = partyBalanceInc(savedTx, 1);
      await applyPartyBalanceInc(savedTx.partyId, inc);
      log.debug('BALANCE', 'Applied party balance delta on create', { id: req.requestId, partyId: savedTx.partyId, inc });
    } catch (balErr) {
      log.error('BALANCE', 'Failed to apply party balance on create — party balance may now be stale', balErr, {
        id: req.requestId, txId: savedTx._id, partyId: savedTx.partyId,
      });
    }
    // Broadcast update once daily balances have finished recalculating.
    recalculateDailyBalances(savedTx.date)
      .then(() => broadcastEvent('transactions_updated'))
      .catch(err => {
        log.error('BALANCES', 'Background recalculation failed after transaction create', err, { txId: savedTx._id });
        broadcastEvent('transactions_updated');
      });
    res.status(201).json(savedTx);
  } catch (err: any) {
    log.error('TXN', 'Error in POST /api/transactions', err, { id: req.requestId, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.put('/api/transactions/:id', authenticate, requireAdmin, async (req, res) => {
  try {
    const oldTx = await Transaction.findById(req.params.id);
    const updatedTx = await Transaction.findByIdAndUpdate(req.params.id, req.body, { new: true });
    if (!oldTx) log.warn('TXN', 'Update targeted a transaction that does not exist', { id: req.requestId, txId: req.params.id });
    else log.info('TXN', 'Updated transaction', {
      id: req.requestId,
      txId: req.params.id,
      before: { partyId: oldTx.partyId, type: oldTx.type, paymentMode: oldTx.paymentMode, cashAmount: oldTx.cashAmount, metalType: oldTx.metalType, metalWeight: oldTx.metalWeight, date: oldTx.date },
      after: updatedTx && { partyId: updatedTx.partyId, type: updatedTx.type, paymentMode: updatedTx.paymentMode, cashAmount: updatedTx.cashAmount, metalType: updatedTx.metalType, metalWeight: updatedTx.metalWeight, date: updatedTx.date },
    });
    // Atomically adjust the party balance: reverse the old impact, apply the new.
    try {
      if (oldTx && updatedTx) {
        if (String(oldTx.partyId) === String(updatedTx.partyId)) {
          await applyPartyBalanceInc(
            updatedTx.partyId,
            mergeInc(partyBalanceInc(oldTx, -1), partyBalanceInc(updatedTx, 1)),
          );
        } else {
          // Party changed on edit: reverse on the old party, apply on the new one.
          log.info('BALANCE', 'Transaction moved between parties — reversing on old, applying on new', {
            id: req.requestId, txId: req.params.id, oldPartyId: oldTx.partyId, newPartyId: updatedTx.partyId,
          });
          await applyPartyBalanceInc(oldTx.partyId, partyBalanceInc(oldTx, -1));
          await applyPartyBalanceInc(updatedTx.partyId, partyBalanceInc(updatedTx, 1));
        }
      }
    } catch (balErr) {
      log.error('BALANCE', 'Failed to apply party balance on update — party balance may now be stale', balErr, {
        id: req.requestId, txId: req.params.id,
      });
    }
    // Run incremental recalculation from the earlier of old/new date
    const recalcFrom = oldTx && updatedTx ? (oldTx.date < updatedTx.date ? oldTx.date : updatedTx.date) : undefined;
    recalculateDailyBalances(recalcFrom)
      .then(() => broadcastEvent('transactions_updated'))
      .catch(err => {
        log.error('BALANCES', 'Background recalculation failed after transaction update', err, { txId: req.params.id });
        broadcastEvent('transactions_updated');
      });
    res.json(updatedTx);
  } catch (err: any) {
    log.error('TXN', 'Error in PUT /api/transactions/:id', err, { id: req.requestId, txId: req.params.id, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.delete('/api/transactions/:id', authenticate, requireAdmin, async (req, res) => {
  try {
    const txToDelete = await Transaction.findById(req.params.id);
    const deleteDate = txToDelete?.date;
    await Transaction.findByIdAndDelete(req.params.id);
    // Atomically reverse the deleted transaction's impact on the party balance.
    if (txToDelete) {
      log.warn('TXN', 'Deleted transaction', {
        id: req.requestId,
        txId: req.params.id,
        partyId: txToDelete.partyId,
        type: txToDelete.type,
        paymentMode: txToDelete.paymentMode,
        cashAmount: txToDelete.cashAmount,
        metalType: txToDelete.metalType,
        metalWeight: txToDelete.metalWeight,
        date: txToDelete.date,
      });
      try {
        await applyPartyBalanceInc(txToDelete.partyId, partyBalanceInc(txToDelete, -1));
      } catch (balErr) {
        log.error('BALANCE', 'Failed to reverse party balance on delete — party balance may now be stale', balErr, {
          id: req.requestId, txId: req.params.id, partyId: txToDelete.partyId,
        });
      }
    } else {
      log.warn('TXN', 'Delete targeted a transaction that does not exist', { id: req.requestId, txId: req.params.id });
    }
    // Run incremental recalculation from the deleted transaction's date
    recalculateDailyBalances(deleteDate)
      .then(() => broadcastEvent('transactions_updated'))
      .catch(err => {
        log.error('BALANCES', 'Background recalculation failed after transaction delete', err, { txId: req.params.id });
        broadcastEvent('transactions_updated');
      });
    res.json({ message: 'Transaction deleted successfully' });
  } catch (err: any) {
    log.error('TXN', 'Error in DELETE /api/transactions/:id', err, { id: req.requestId, txId: req.params.id });
    res.status(500).json({ error: err.message });
  }
});

// CRUD Routes for Reminders
// Optional ?partyId=<id> filters server-side so party views don't download the
// whole reminders collection just to keep the rows for one party.
app.get('/api/reminders', async (req, res) => {
  try {
    const { partyId } = req.query as Record<string, string | undefined>;
    const filter: Record<string, any> = {};
    if (partyId) filter.partyId = partyId;
    const reminders = await Reminder.find(filter).sort({ date: 1 }).lean();
    log.debug('REMINDERS', `Returning ${reminders.length} reminder(s)`, { id: req.requestId, partyId });
    res.json(reminders);
  } catch (err: any) {
    log.error('REMINDERS', 'Error in GET /api/reminders', err, { id: req.requestId, query: req.query });
    res.status(500).json({ error: err.message });
  }
});
app.post('/api/reminders', async (req, res) => {
  try {
    const newReminder = new Reminder(req.body);
    const savedReminder = await newReminder.save();
    log.info('REMINDERS', 'Created reminder', { id: req.requestId, reminderId: savedReminder._id, partyId: savedReminder.partyId, date: savedReminder.date });
    res.status(201).json(savedReminder);
  } catch (err: any) {
    log.error('REMINDERS', 'Error in POST /api/reminders', err, { id: req.requestId, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.put('/api/reminders/:id', async (req, res) => {
  try {
    const updatedReminder = await Reminder.findByIdAndUpdate(req.params.id, req.body, { new: true });
    if (!updatedReminder) log.warn('REMINDERS', 'Update matched no reminder', { id: req.requestId, reminderId: req.params.id });
    else log.info('REMINDERS', 'Updated reminder', { id: req.requestId, reminderId: req.params.id });
    res.json(updatedReminder);
  } catch (err: any) {
    log.error('REMINDERS', 'Error in PUT /api/reminders/:id', err, { id: req.requestId, reminderId: req.params.id, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.delete('/api/reminders/:id', async (req, res) => {
  try {
    await Reminder.findByIdAndDelete(req.params.id);
    log.info('REMINDERS', 'Deleted reminder', { id: req.requestId, reminderId: req.params.id });
    res.json({ message: 'Reminder deleted successfully' });
  } catch (err: any) {
    log.error('REMINDERS', 'Error in DELETE /api/reminders/:id', err, { id: req.requestId, reminderId: req.params.id });
    res.status(500).json({ error: err.message });
  }
});

// CRUD Routes for Appointments
app.get('/api/appointments', async (req, res) => {
  try {
    const appointments = await Appointment.find().sort({ date: 1 });
    log.debug('APPTS', `Returning ${appointments.length} appointment(s)`, { id: req.requestId });
    res.json(appointments);
  } catch (err: any) {
    log.error('APPTS', 'Error in GET /api/appointments', err, { id: req.requestId });
    res.status(500).json({ error: err.message });
  }
});
app.post('/api/appointments', async (req, res) => {
  try {
    const newAppointment = new Appointment(req.body);
    const savedAppointment = await newAppointment.save();
    log.info('APPTS', 'Created appointment', { id: req.requestId, appointmentId: savedAppointment._id, date: savedAppointment.date });
    res.status(201).json(savedAppointment);
  } catch (err: any) {
    log.error('APPTS', 'Error in POST /api/appointments', err, { id: req.requestId, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.put('/api/appointments/:id', async (req, res) => {
  try {
    const updatedAppointment = await Appointment.findByIdAndUpdate(req.params.id, req.body, { new: true });
    if (!updatedAppointment) log.warn('APPTS', 'Update matched no appointment', { id: req.requestId, appointmentId: req.params.id });
    else log.info('APPTS', 'Updated appointment', { id: req.requestId, appointmentId: req.params.id });
    res.json(updatedAppointment);
  } catch (err: any) {
    log.error('APPTS', 'Error in PUT /api/appointments/:id', err, { id: req.requestId, appointmentId: req.params.id, body: req.body });
    res.status(400).json({ error: err.message });
  }
});
app.delete('/api/appointments/:id', async (req, res) => {
  try {
    await Appointment.findByIdAndDelete(req.params.id);
    log.info('APPTS', 'Deleted appointment', { id: req.requestId, appointmentId: req.params.id });
    res.json({ message: 'Appointment deleted successfully' });
  } catch (err: any) {
    log.error('APPTS', 'Error in DELETE /api/appointments/:id', err, { id: req.requestId, appointmentId: req.params.id });
    res.status(500).json({ error: err.message });
  }
});

// Health check endpoint
app.get('/api/health', (req, res) => {
  const mem = process.memoryUsage();
  res.json({
    status: 'ok',
    database: isMongoConnected ? 'connected' : 'fallback_in_memory',
    fallbackActive: !isMongoConnected,
    // Handy when diagnosing from the phone: is the process fresh (did it crash
    // and restart?), how many live SSE listeners, and how much memory it holds.
    uptimeSeconds: Math.round(process.uptime()),
    sseClients: sseClients.length,
    memoryMB: {
      rss: Math.round(mem.rss / 1048576),
      heapUsed: Math.round(mem.heapUsed / 1048576),
    },
    logLevel: loggerConfig.MIN_LEVEL,
  });
});

// Server time endpoint for network clock synchronization
app.get('/api/time', (req, res) => {
  res.json({
    serverTime: new Date().toISOString(),
  });
});

// SSE Endpoint
app.get('/api/events', (req: Request, res: Response) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  // Initial connection event
  res.write('data: connected\n\n');

  sseClients.push(res);
  log.info('SSE', `Client connected (${sseClients.length} total)`, { id: req.requestId, ip: req.ip });

  // Heartbeat: send a comment ping periodically so proxies (Hostinger / mobile
  // carriers) don't silently drop the idle stream, and so the client can detect
  // a dead connection quickly and reconnect.
  const heartbeat = setInterval(() => {
    res.write(': keep-alive\n\n');
  }, 20000);

  req.on('close', () => {
    clearInterval(heartbeat);
    sseClients = sseClients.filter(client => client !== res);
    log.info('SSE', `Client disconnected (${sseClients.length} remaining)`, { id: req.requestId });
  });
});

// Auto-logout expired sessions every 1 minute
setInterval(async () => {
  const now = new Date();
  if (isMongoConnected) {
    try {
      const expiredProfiles = await UserProfile.find({
        status: 'approved',
        expiresAt: { $lte: now },
      });
      for (const profile of expiredProfiles) {
        profile.status = 'inactive';
        profile.sessionActive = false;
        profile.expiresAt = null;
        profile.approvedDeviceId = null;
        profile.approvedDeviceBrand = null;
        profile.approvedDeviceModel = null;
        await profile.save();
        log.info('CRON', `DB profile ${profile.name} automatically logged out due to expiry`, { profileId: profile._id });
      }
      if (expiredProfiles.length > 0) {
        broadcastProfilesUpdated();
      }
    } catch (err) {
      log.error('CRON', 'Auto-logout sweep failed', err);
    }
  } else {
    let hadExpired = false;
    fallbackUserProfiles.forEach(profile => {
      if (profile.status === 'approved' && profile.expiresAt && profile.expiresAt <= now) {
        profile.status = 'inactive';
        profile.sessionActive = false;
        profile.expiresAt = null;
        profile.approvedDeviceId = null;
        profile.approvedDeviceBrand = null;
        profile.approvedDeviceModel = null;
        log.info('CRON', `In-memory profile ${profile.name} automatically logged out due to expiry`, { profileId: profile._id });
        hadExpired = true;
      }
    });
    if (hadExpired) {
      broadcastProfilesUpdated();
    }
  }
}, 60 * 1000);

// These two must stay LAST — after every route — so they only catch what no
// route handled and what no route's own try/catch already answered.
app.use(notFoundHandler);
app.use(errorHandler);

const server = app.listen(PORT, () => {
  log.info('STARTUP', `Swastik server listening on port ${PORT}`, {
    pid: process.pid,
    node: process.version,
    env: process.env.NODE_ENV || 'development',
    logLevel: loggerConfig.MIN_LEVEL,
    logFile: loggerConfig.LOG_TO_FILE ? loggerConfig.LOG_DIR : 'disabled (console only)',
    logBodies: loggerConfig.LOG_BODIES,
  });
});

server.on('error', (err) => {
  log.error('STARTUP', `Server failed to bind port ${PORT}`, err);
});
