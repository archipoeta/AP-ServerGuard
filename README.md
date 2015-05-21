# AP ServerGuard
> For 7 Days To Die Servers

7 Days To Die is a great multiplayer game with no true PVE mode, which unfortunately makes it a target for griefer-types. This highly configurable application impliments an infraction/enforcement system for hybrid-pvp (toggleable,) and pure-pve modes, a chat profanity filter, player reporting system, etc. It also features the ability
to protect multiple game server instances, and requires no dependencies other than `perl` and `expect`, (which are installed by default in every linux distro.)

### Installation
1. Clone the repo, `git clone https://github.com/archipoeta/AP-ServerGuard.git`
2. `cd` into the repo directory, `cd AP-ServerGuard/`
3. Run the provided installer with optional arguments:
 - `# install.sh [INIT_DIR] [BIN_PATH]`
 - *(Skip #4)*

  *-OR-*
4. Copy `cp` or Symlink `ln -s` the init script and perl app into your rc/init directories and into your $PATH respectively. An example suitable for most distros:
  - `# cp ap_serverguard.init /etc/init.d/ap_serverguard`
  - `# cp ap_serverguard.pl /usr/local/bin/ap_serverguard`

3. Now you *must* edit the config file example and rename it to `.cfg`
  - `# vi ap_serverguard.cfg.example`
  - `# mv ap_serverguard.cfg.example ap_serverguard.cfg`

4. You should be ready to go, go ahead and start the daemon.
  - `# /etc/init.d/ap_serverguard start`

- Note:
  - `# /etc/init.d/ap_serverguard stop`
  - `# /etc/init.d/ap_serverguard restart`

### Gameplay
In game, the following commands are implemented:
        * AP ServerGuard Command Help:
          /pvp     - Toggle PVP mode on and off.
          /report  - Report unwated PVP action to infract your killer.
          /help    - This usage menu. :)

### Development
Want to contribute? Great!  
AP-ServerGuard is in `perl`

### Roadmap
 - Add More Features
 - Fix Bugs :)

### License
MIT
