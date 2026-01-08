
# LiveTracker

Develop a Flutter mobile application that allows users to authenticate securely, fetch their current location, and display it on a map.

## Functional Requirements

### 1) User Authentication

- User registration and login using email and password
- Secure session management (persisted sign-in via Firebase Auth)
- Proper error handling (invalid credentials, network issues, disabled auth method)

### 2) Location Access

- Request runtime location permission
- Fetch the user’s current GPS coordinates
- Handle permission denial gracefully (clear UI state + retry path)

### 3) Map Integration

- Display the current location on a map
- Show a marker at the user’s live position

## Project details

- Auth: Firebase Email/Password (`firebase_auth`)
- Location: live GPS updates with runtime permissions (`geolocator` + permission handling)
- Map: OpenStreetMap tiles using `flutter_map` (no API key required)


