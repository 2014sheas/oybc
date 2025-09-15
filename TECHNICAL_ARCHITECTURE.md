# Social Bingo App - Technical Architecture

## Overview

Event-based social bingo mobile app built with React Native, Expo, and Firebase. Players create games, invite others, and compete to complete bingo boards with real-world events.

## Tech Stack

- **Frontend**: React Native with Expo
- **Backend**: Firebase (Firestore, Authentication, Storage, Functions)
- **Real-time**: Firebase Realtime Database
- **State Management**: Redux Toolkit + RTK Query
- **Navigation**: React Navigation 6
- **UI Components**: React Native Elements + Custom Components
- **Offline Support**: Redux Persist + Firebase Offline Persistence

## Database Schema

### Users Collection

```typescript
interface User {
  uid: string;
  email: string;
  displayName: string;
  photoURL?: string;
  isGuest: boolean;
  createdAt: Timestamp;
  lastActiveAt: Timestamp;
  gameHistory: string[]; // Array of game IDs
}
```

### Games Collection

```typescript
interface Game {
  id: string;
  ownerId: string;
  name: string;
  description?: string;
  status:
    | "draft"
    | "upcoming"
    | "waiting_to_start"
    | "active"
    | "completed"
    | "cancelled";
  boardSize: 3 | 4 | 5;
  maxPlayers: number;
  startTime: Timestamp;
  endTime?: Timestamp;
  createdAt: Timestamp;
  updatedAt: Timestamp;

  // Game Configuration
  config: {
    centerSquareType: "free" | "custom";
    centerSquareEvent?: string;
    verificationRequired: boolean;
    verificationMethod: "owner_only" | "any_player" | "majority_vote";
    eventContribution: "owner_only" | "all_players";
    allowEventDeletion: boolean;
  };

  // Players
  players: {
    [userId: string]: {
      displayName: string;
      joinedAt: Timestamp;
      isOwner: boolean;
      board?: BingoBoard;
      completedSquares: string[]; // Array of square IDs
      score: number;
    };
  };

  // Events
  events: {
    [eventId: string]: {
      title: string;
      description: string;
      category: string;
      createdBy: string;
      createdAt: Timestamp;
      verificationRequired: boolean;
      verificationType: "photo" | "text" | "location" | "timestamp" | "any";
    };
  };

  // Board Layout
  boardLayout: {
    [squareId: string]: {
      eventId: string;
      position: { row: number; col: number };
    };
  };

  // Verifications
  verifications: {
    [verificationId: string]: {
      playerId: string;
      squareId: string;
      eventId: string;
      evidence: {
        type: "photo" | "text" | "location" | "timestamp";
        data: any;
        submittedAt: Timestamp;
      };
      status: "pending" | "approved" | "rejected";
      verifiedBy?: string;
      verifiedAt?: Timestamp;
      reason?: string;
    };
  };

  // Chat Messages
  chatMessages: {
    [messageId: string]: {
      playerId: string;
      displayName: string;
      message: string;
      timestamp: Timestamp;
      type: "text" | "system";
    };
  };
}
```

### Event Templates Collection

```typescript
interface EventTemplate {
  id: string;
  name: string;
  category: string;
  events: {
    title: string;
    description: string;
    verificationRequired: boolean;
    verificationType: "photo" | "text" | "location" | "timestamp" | "any";
  }[];
  isPublic: boolean;
  createdBy: string;
  createdAt: Timestamp;
  usageCount: number;
}
```

## Component Architecture

### Navigation Structure

```
AppNavigator
├── AuthNavigator (Stack)
│   ├── LoginScreen
│   ├── RegisterScreen
│   └── GuestJoinScreen
├── MainNavigator (Tab)
│   ├── HomeScreen
│   ├── GameLobbyScreen
│   ├── GameBoardScreen
│   ├── ProfileScreen
│   └── GameHistoryScreen
└── GameNavigator (Stack)
    ├── CreateGameScreen
    ├── GameSettingsScreen
    ├── EventManagementScreen
    └── JoinGameScreen
```

### Key Components

#### Game Creation Flow

- `CreateGameScreen`: Basic game setup
- `GameSettingsScreen`: Advanced configuration
- `EventManagementScreen`: Add/edit events and templates
- `InvitePlayersScreen`: Share game codes/links

#### Game Lobby

- `GameLobbyScreen`: Player list, chat, event management
- `PlayerListComponent`: Show joined players
- `EventListComponent`: Display and manage events
- `ChatComponent`: Real-time messaging

#### Gameplay

- `GameBoardScreen`: Main bingo board interface
- `BingoBoardComponent`: 5x5 grid with events
- `SquareComponent`: Individual bingo square
- `VerificationModal`: Submit evidence for squares
- `LeaderboardComponent`: Real-time player scores

#### Verification System

- `VerificationQueueScreen`: Pending verifications
- `VerificationItemComponent`: Individual verification
- `EvidenceViewerComponent`: Display submitted evidence

## State Management

### Redux Store Structure

```typescript
interface RootState {
  auth: AuthState;
  games: GamesState;
  ui: UIState;
  offline: OfflineState;
}

interface AuthState {
  user: User | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  error: string | null;
}

interface GamesState {
  currentGame: Game | null;
  myGames: Game[];
  gameHistory: Game[];
  isLoading: boolean;
  error: string | null;
}

interface UIState {
  activeTab: string;
  modals: {
    verification: boolean;
    settings: boolean;
    invite: boolean;
  };
  notifications: Notification[];
}
```

### RTK Query API Slices

- `authApi`: Authentication endpoints
- `gamesApi`: Game CRUD operations
- `eventsApi`: Event management
- `verificationApi`: Verification system
- `chatApi`: Real-time messaging

## Real-time Features

### Firebase Realtime Database Structure

```
/games/{gameId}/
├── players/{playerId}/
│   ├── completedSquares
│   ├── score
│   └── lastActive
├── chat/
│   └── {messageId}/
├── verifications/
│   └── {verificationId}/
└── gameState/
    ├── status
    ├── currentPlayer
    └── winner
```

### Real-time Listeners

- Game state changes (status, players, scores)
- Chat messages
- Verification updates
- Board completion events

## Offline Support

### Redux Persist Configuration

- User authentication state
- Current game state
- Pending verifications
- Offline actions queue

### Offline Actions

- Check off squares (queue for sync)
- Submit verifications (queue for sync)
- Send chat messages (queue for sync)
- View game history (cached locally)

### Sync Strategy

- Automatic sync when online
- Manual sync option
- Conflict resolution for concurrent edits
- Retry failed actions

## Security Rules

### Firestore Security Rules

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users can read/write their own data
    match /users/{userId} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }

    // Games: owner can write, players can read
    match /games/{gameId} {
      allow read: if request.auth != null &&
        (resource.data.ownerId == request.auth.uid ||
         request.auth.uid in resource.data.players.keys());
      allow write: if request.auth != null &&
        resource.data.ownerId == request.auth.uid;
    }

    // Event templates: public read, owner write
    match /eventTemplates/{templateId} {
      allow read: if resource.data.isPublic == true;
      allow write: if request.auth != null &&
        resource.data.createdBy == request.auth.uid;
    }
  }
}
```

## Performance Considerations

### Optimization Strategies

- Lazy loading for game history
- Image compression for verification photos
- Pagination for chat messages
- Debounced real-time updates
- Memoized components for board rendering

### Caching

- Game templates cached locally
- User avatars cached
- Recent games cached
- Offline game state persisted

## Development Phases

### Phase 1: Foundation (Weeks 1-2)

- Project setup with Expo
- Firebase configuration
- Basic authentication (email/password + Google)
- Navigation structure
- Basic UI components

### Phase 2: Game Creation (Weeks 3-4)

- Game creation flow
- Game settings configuration
- Event template system
- Basic game state management

### Phase 3: Game Joining (Weeks 5-6)

- Join game flow (link/code/QR)
- Guest user support
- Game lobby interface
- Player management

### Phase 4: Core Gameplay (Weeks 7-9)

- Bingo board generation
- Square interaction
- Verification system
- Basic scoring

### Phase 5: Real-time Features (Weeks 10-11)

- Real-time updates
- Chat system
- Live leaderboard
- Push notifications

### Phase 6: Polish & Testing (Weeks 12-13)

- Offline support
- Performance optimization
- UI/UX polish
- Testing and bug fixes

## Testing Strategy

### Unit Tests

- Redux reducers and actions
- Utility functions
- Component logic

### Integration Tests

- API endpoints
- Real-time functionality
- Offline sync

### E2E Tests

- Complete game flow
- Multi-player scenarios
- Offline/online transitions

### Manual Testing

- Multi-device testing
- Different user types (owner, player, guest)
- Edge cases and error handling

## Deployment

### Development

- Expo Go for rapid iteration
- Firebase emulators for local development
- TestFlight for iOS testing

### Production

- EAS Build for production builds
- Firebase production environment
- App Store and Google Play deployment

## Monitoring & Analytics

### Firebase Analytics

- User engagement metrics
- Game completion rates
- Feature usage statistics

### Error Tracking

- Crashlytics for crash reporting
- Custom error logging
- Performance monitoring

## Future Considerations

### Scalability

- Database sharding for large games
- CDN for image storage
- Caching strategies for high traffic

### Advanced Features

- Push notifications
- Social media integration
- Advanced analytics
- Premium features
- Community features

This architecture provides a solid foundation for the social bingo app while maintaining flexibility for future enhancements and scaling.
