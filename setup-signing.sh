#!/bin/bash
# Setup local code signing for development
# Run this ONCE to create a self-signed certificate

set -e

CERT_NAME="WhisperVoice Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "========================================"
echo "  Whisper Voice - Setup Code Signing   "
echo "========================================"
echo ""

# Check if certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists!"
    echo ""
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo ""
    echo "You're all set. Run ./WhisperVoice/dev.sh to build."
    exit 0
fi

echo "Creating self-signed code signing certificate..."
echo "(This may ask for your keychain password)"
echo ""

# Create certificate using certtool (built into macOS)
# This creates a self-signed certificate for code signing
cat > /tmp/cert_request.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>certType</key>
    <string>Self-Signed Certificate</string>
    <key>keySize</key>
    <integer>2048</integer>
    <key>subjectCommonName</key>
    <string>WhisperVoice Dev</string>
    <key>validityPeriod</key>
    <integer>3650</integer>
    <key>keyUsage</key>
    <array>
        <string>digitalSignature</string>
    </array>
    <key>extendedKeyUsage</key>
    <array>
        <string>codeSigning</string>
    </array>
</dict>
</plist>
EOF

# Use security command to create certificate
# Alternative method: manual via Keychain Access
echo "Method 1: Trying automated certificate creation..."

# Try creating with security command (may not work on all macOS versions)
if ! security create-identity -s "$CERT_NAME" "$KEYCHAIN" 2>/dev/null; then
    echo ""
    echo "Automated creation failed. Using manual method..."
    echo ""
    echo "Opening Keychain Access. Please:"
    echo "  1. Menu: Keychain Access > Certificate Assistant > Create a Certificate"
    echo "  2. Name: $CERT_NAME"
    echo "  3. Identity Type: Self Signed Root"
    echo "  4. Certificate Type: Code Signing"
    echo "  5. Click Create"
    echo ""

    # Open Certificate Assistant directly
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || \
    open -a "Keychain Access"

    echo "After creating, verify with:"
    echo "  security find-identity -v -p codesigning"
    exit 0
fi

rm -f /tmp/cert_request.plist

echo ""
echo "Certificate created successfully!"
echo ""
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo ""
echo "Now run ./WhisperVoice/dev.sh to build with preserved permissions."
