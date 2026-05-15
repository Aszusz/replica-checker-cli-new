#!/usr/bin/env bash
set -euo pipefail

# generate-server-id.sh — Generate an additional Domino server ID from the
# local server's certifier and add the new server to LocalDomainAdmins.
#
# Runs ON the source Domino server. Uses domino.sh for lifecycle (JeDI
# Gstop/Gstart). The bundled CreateAdditionalServerJNA.jar drives the
# registration; an inline AddGroupMember program updates names.nsf.
#
# Usage:
#   generate-server-id.sh --name <fqdn> --cert-pass <pwd> [--output <path>] [--org <O>]
#
# Reads notes.ini for the registration server name and Domino domain. The
# new server is registered under the same certifier O= as the local server,
# unless --org overrides it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/domino.sh"

##############################################################################
# Constants + helpers
##############################################################################

NOTES_LIB="/opt/hcl/domino/notes/latest/linux"
NOTES_JAR="$NOTES_LIB/ndext/Notes.jar"
NOTES_DATA="/local/notesdata"
NOTES_INI="$NOTES_DATA/notes.ini"
JAR_PATH="$SCRIPT_DIR/CreateAdditionalServerJNA.jar"

step() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$1" "$2"; }
ok()   { printf '\033[1;32m%s\033[0m\n' "$1"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$1"; }

usage() {
    cat <<'USAGE'
Usage: generate-server-id.sh --name <fqdn> --cert-pass <pwd> [--output <path>] [--org <O>]

  --name        New server FQDN, e.g. ivisaur.heroes.com
  --cert-pass   Certifier (admin) ID password
  --output      Where to put the resulting .id file (default: ./<fqdn>.id)
  --org         Override the certifier O= (default: inferred from notes.ini ServerName)
USAGE
    exit 1
}

##############################################################################
# Parse args
##############################################################################

TARGET_FQDN="" CERT_PASS="" OUTPUT="" ORG_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)       TARGET_FQDN="$2"; shift 2 ;;
        --cert-pass)  CERT_PASS="$2"; shift 2 ;;
        --output)     OUTPUT="$2"; shift 2 ;;
        --org)        ORG_OVERRIDE="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            fail "Unknown arg: $1" ;;
    esac
done

[[ -n "$TARGET_FQDN" ]] || usage
[[ -n "$CERT_PASS"   ]] || usage
[[ -z "$OUTPUT"      ]] && OUTPUT="$PWD/${TARGET_FQDN}.id"

##############################################################################
# [1/8] Preflight
##############################################################################

step "1/8" "Preflight checks"

[[ -f "$JAR_PATH"  ]] || fail "JAR not found at $JAR_PATH"
[[ -f "$NOTES_JAR" ]] || fail "Notes.jar not found at $NOTES_JAR — is Domino installed?"
[[ -d "$NOTES_LIB" ]] || fail "Domino lib dir missing: $NOTES_LIB"
[[ -f "$NOTES_INI" ]] || fail "notes.ini not found at $NOTES_INI"
command -v java  >/dev/null 2>&1 || fail "java is not on PATH"
command -v javac >/dev/null 2>&1 || fail "javac is not on PATH (need a JDK, not just JRE)"

# Detect Domino service user from data-dir ownership.
DOMINO_USER=$(stat -c '%U' "$NOTES_DATA" 2>/dev/null) \
    || fail "stat($NOTES_DATA) failed; cannot detect Domino service user"
[[ -n "$DOMINO_USER" ]] || fail "Empty owner for $NOTES_DATA"

# Read registration server + domain from notes.ini.
SERVER_NAME=$(awk -F= '/^ServerName=/ { print $2 }' "$NOTES_INI" | tr -d '\r\n ')
DOMAIN_NAME=$(awk -F= '/^Domain=/      { print $2 }' "$NOTES_INI" | tr -d '\r\n ')
[[ -n "$SERVER_NAME" ]] || fail "ServerName= not found in $NOTES_INI"
[[ -n "$DOMAIN_NAME" ]] || fail "Domain= not found in $NOTES_INI"

# Infer org from ServerName by taking the rightmost "/O=…" segment, or the
# last "/…" segment if abbreviated. Falls back to --org if neither matches.
if [[ -n "$ORG_OVERRIDE" ]]; then
    ORG="$ORG_OVERRIDE"
elif [[ "$SERVER_NAME" =~ /O=([^/]+)$ ]]; then
    ORG="${BASH_REMATCH[1]}"
elif [[ "$SERVER_NAME" =~ /([^/]+)$ ]]; then
    ORG="${BASH_REMATCH[1]}"
else
    fail "Could not infer certifier O= from ServerName='$SERVER_NAME'; pass --org explicitly"
fi

TARGET_CN="CN=${TARGET_FQDN}/O=${ORG}"

echo "  java:    $(java -version 2>&1 | head -1)"
echo "  user:    $DOMINO_USER (auto-detected from $NOTES_DATA)"
echo "  server:  $SERVER_NAME"
echo "  domain:  $DOMAIN_NAME"
echo "  org:     $ORG"
echo "  target:  $TARGET_FQDN ($TARGET_CN)"
echo "  output:  $OUTPUT"

##############################################################################
# [2/8] Ensure setup.json exists
##############################################################################

step "2/8" "Checking setup.json"

if [[ ! -f "$NOTES_DATA/setup.json" ]]; then
    echo "  setup.json missing — creating from notes.ini values..."
    sudo -u "$DOMINO_USER" tee "$NOTES_DATA/setup.json" >/dev/null <<EOF
{
  "serverSetup": {
    "server": { "name": "$SERVER_NAME", "domainName": "$DOMAIN_NAME" },
    "org": { "certifierPassword": "$CERT_PASS" }
  }
}
EOF
    echo "  setup.json created."
else
    echo "  setup.json exists."
fi

##############################################################################
# [3/8] Stop Domino (via JeDI)
##############################################################################

step "3/8" "Stopping Domino"
stop_domino --verbose

##############################################################################
# [4/8] Write additional.properties
##############################################################################

step "4/8" "Writing /tmp/additional.properties"

ADDITIONAL_PROPS="/tmp/additional.properties"
ID_FILE_TMP="/tmp/${TARGET_FQDN}.id"

cat > "$ADDITIONAL_PROPS" <<EOF
server.name=${TARGET_FQDN}
server.id.password=
server.id.title=${TARGET_FQDN}
server.id.output=${ID_FILE_TMP}
EOF

echo "  server.name=$TARGET_FQDN"
echo "  server.id.output=$ID_FILE_TMP"

##############################################################################
# [5/8] Generate server ID via JAR
##############################################################################

step "5/8" "Running CreateAdditionalServerJNA.jar"

sudo -u "$DOMINO_USER" bash -c "
    export LD_LIBRARY_PATH='$NOTES_LIB'
    cd '$NOTES_DATA'
    java -jar '$JAR_PATH' '$ADDITIONAL_PROPS'
" || fail "CreateAdditionalServerJNA.jar failed"

[[ -f "$ID_FILE_TMP" ]] || fail "Expected ID file not created at $ID_FILE_TMP"
echo "  Created $ID_FILE_TMP"

##############################################################################
# [6/8] Add new server to LocalDomainAdmins
##############################################################################

step "6/8" "Adding $TARGET_CN to LocalDomainAdmins"

ADDGROUP_SRC="/tmp/AddGroupMember.java"
cat > "$ADDGROUP_SRC" <<'JAVAEOF'
import lotus.domino.*;

public class AddGroupMember {
    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.out.println("Usage: AddGroupMember <groupName> <memberToAdd>");
            System.exit(1);
        }
        String groupName = args[0];
        String newMember = args[1];

        NotesThread.sinitThread();
        try {
            Session session = NotesFactory.createSession();
            Database namesDb = session.getDatabase("", "names.nsf");
            View groups = namesDb.getView("($VIMGroups)");
            Document groupDoc = groups.getDocumentByKey(groupName, true);
            if (groupDoc == null) {
                System.out.println("Group not found: " + groupName);
                System.exit(1);
            }

            java.util.Vector members = groupDoc.getItemValue("Members");
            for (Object m : members) {
                if (m.toString().equalsIgnoreCase(newMember)) {
                    System.out.println(newMember + " is already in " + groupName);
                    System.exit(0);
                }
            }

            members.add(newMember);
            groupDoc.replaceItemValue("Members", members);
            groupDoc.computeWithForm(false, false);
            groupDoc.save(true, false);
            System.out.println("Added " + newMember + " to " + groupName);
        } finally {
            NotesThread.stermThread();
        }
    }
}
JAVAEOF

sudo -u "$DOMINO_USER" javac -cp "$NOTES_JAR" -d /tmp "$ADDGROUP_SRC" \
    || fail "Failed to compile AddGroupMember.java"

GROUP_OUTPUT=$(sudo -u "$DOMINO_USER" bash -c "
    export LD_LIBRARY_PATH='$NOTES_LIB'
    cd '$NOTES_DATA'
    java -cp /tmp:'$NOTES_JAR' -Djava.library.path='$NOTES_LIB' \
        AddGroupMember LocalDomainAdmins '$TARGET_CN'
" 2>&1) || {
    echo "$GROUP_OUTPUT"
    warn "Failed to add $TARGET_CN to LocalDomainAdmins."
    warn "Manual fix needed after Domino starts."
}

echo "  $GROUP_OUTPUT"

##############################################################################
# [7/8] Start Domino (via JeDI)
##############################################################################

step "7/8" "Starting Domino"
start_domino --verbose

##############################################################################
# [8/8] Move ID file + cleanup
##############################################################################

step "8/8" "Moving ID file to $OUTPUT"

OUTPUT_DIR=$(dirname "$OUTPUT")
[[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR"

sudo chown "$(id -u):$(id -g)" "$ID_FILE_TMP"
mv "$ID_FILE_TMP" "$OUTPUT"

[[ -f "$OUTPUT" ]] || fail "ID file missing at $OUTPUT after move"
SIZE=$(wc -c < "$OUTPUT" | tr -d ' ')
[[ "$SIZE" -gt 0 ]] || fail "ID file is empty"
echo "  Saved: $OUTPUT ($SIZE bytes)"

rm -f "$ADDITIONAL_PROPS" "$ADDGROUP_SRC" /tmp/AddGroupMember.class 2>/dev/null || true
echo "  Temp files cleaned."

echo
ok "Done. Server ID for $TARGET_FQDN saved to $OUTPUT."
ok "$TARGET_CN added to LocalDomainAdmins."
