curl -fsSL https://raw.githubusercontent.com/pjain/setup-macos/main/bootstrap.sh | bash -s -- --profile dev
cd ~/projects/setup-macos
SETUP_DRY_RUN=1 ./install.sh --profile dev   # resolves all sources, changes nothing
./update.sh --check --profile dev            # installed-vs-latest table
cp ~/.local/state/setup-macos/prefs-audit.tsv ~/Desktop/   # matrix artifact to send back

