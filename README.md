# IrssiNtfy
Irssi script to send notifications to your phone from Irssi via ntfy; see https://ntfy.sh/

This hack job is based on IrssiNotifier; see https://github.com/murgo/IrssiNotifier

# Setup
1. Host or rent an ntfy instance; see https://ntfy.sh/ for releases or service options
2. Install ntfy app to your phone; again see https://ntfy.sh/ for appstore links
3. Add subscription to your ntfy app: enter topic name, for example irssi, and enter your ntfy server url
4. Copy irssintfy.pl to ~/.irssi/scripts/autorun/ and load in Irssi: /script load autorun/irssintfy
5. In irssi, configure ntfy notification url (with topic name as the path): /set irssintfy_api_url https://<your_ntfy_server_address>/irssi
6. If authentication is needed to send notifications, create an authentication token for your ntfy user and configure it to irssi: /set irssintfy_auth_token tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx
7. Configure other settings starting with irssintfy_ to your taste and remember to /save

# Settings
## irssintfy_api_url
Your ntfy server full URL
## irssintfy_auth_token
Your ntfy server user authentication token if one is needed to send notifications
## irssintfy_away_only
Only send notifications when you are away when set
## irssintfy_enable_dcc
Send notifications for DCC chats when set
## irssintfy_https_proxy
HTTPS proxy URL if you need to use one
## irssintfy_ignore_active_window
Do not send notifications for currently active window when set
## irssintfy_ignored_channels
Do not send notifications for these space separated channels when set
## irssintfy_ignored_highlight_patterns
Do not send notifications for these space separated perl regex patterns when set
## irssintfy_ignored_nicks
Do not send notifications for these space separated nicks when set
## irssintfy_ignored_servers
Do not send notifications for these space separated IRC servers when set
## irssintfy_require_idle_seconds
Only send notifications if there was no user input for this many seconds
## irssintfy_required_public_highlight_patterns
Only send notifications for these space separated public highlight regex patterns when set
## irssintfy_screen_detached_only
Only send notifications when your screen/tmux session is detached when set

# Disclaimer
This is a hack job. Use at your own risk.

# Screenshot
![Screenshot from ntfy Android app](images/irssintfy.jpg)
