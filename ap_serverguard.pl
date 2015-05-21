#!/usr/bin/env perl

##
#	Title: AP ServerGuard
#	Desc: AP ServerGuard for 7 Days To Die Manager
#	Author: Archpoet
#	Email: archipoetae@gmail.com
#	Date: 2015.05.15
#	See VERSION for $version
##

use strict;
use warnings;
use Getopt::Long;
use POSIX qw( WNOHANG );

our $config;
our ($global_infraction_map, $global_players_map);

my ($config_file, $daemon, $help);

my $app_name = "ap_serverguard";
my $app_version = get_app_version();

#
# OPTIONS
#

GetOptions(
	'c=s'		=> \$config_file,
	'daemon!'	=> \$daemon,
	'help!'		=> \$help,
);

#
# CONFIG
#

$config_file = "$app_name.cfg" unless ( $config_file );
require "$config_file";

# maybe move to config?
$config->{main_data_file} = "data/infract.dat";
$config->{mode_data_file} = "data/mode_times.dat";
$config->{kill_data_file} = "data/murders.dat";

$config->{log_file} = "logs/serverguard.log";
$config->{telnet_cmd} = "bin/ap_telnet_cmd_wrapper";

# Runtime tracking
my ($global_pvp_mode_string, $global_enf_modes_string);
my (%global_announce_map, $mode_change_map, $victims_killers_map);
my @global_instance_fhs;

# PVP Mode Map
my %pvp_modes = (
	'0'	=> "Full PVP",
	'1' => "Pure PVE",
	'2' => "Hybrid PVP/PVE",
);

# Fake Chat Commands
my %command_map = (
	'help' => \&handle_help_command,
	'pvp' => \&handle_pvp_command,
	'report' => \&handle_report_command,
);

# Handler Map // JSON-style
my @handler_map = (
	{
		name => "Player Connected.",
		match => 'Player connected,',
		method => \&handle_player_connected
	},
	{
		name => "PVP Action.",
		match => 'Player.+eliminated Player',
		method => \&handle_player_versus_player
	},
	{
		name => "Chat Message.",
		match => 'GMSG: [^:]+:',
		method => \&handle_chat_message
	},
	{
		name => "Console Command.",
		match => 'Denying command ',
		method => \&handle_console_command
	},
);

# misc...
my $log_timestamp_regex = '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$';

# pids / proc mgmt
my @children;
$config->{pid} = undef;
$config->{ppid} = undef;
$config->{pid_file} = "/var/run/$app_name.pid";

#
# SIGNAL HANDLERS
#

# try to shut down gracefully
$SIG{'HUP'}     = 'IGNORE';
$SIG{'INT'}     = sub { quit( "$app_name received an INT signal... shutting down."  ); };
$SIG{'QUIT'}    = sub { quit( "$app_name received a  QUIT signal... shutting down." ); };
$SIG{'ABRT'}    = sub { quit( "$app_name received an ABRT signal... shutting down." ); };
$SIG{'TERM'}    = sub { quit( "$app_name received a TERM signal... shutting down." ); };

# display usage unless daemonize()
usage() unless ( $daemon );
# or if someone actually wants it
usage() if ( $help );

# double fork
if (fork()) { exit(0); }
if (fork()) { exit(0); }

# make sure we're not running already
write_pid_file();

# iterate over instances and store their output logs'
# open filehandles in a hash for later
for ( my $i = 0 ; $i < scalar @{ $config->{instances} } ; $i++ ) {
	my $instance = $config->{instances}->[$i];
	if ( $instance->{output_log} ) {

		# open the logs for continuous reading
		open( my $fh, "<", $instance->{output_log} )
		or warn "Couldn't open $instance->{output_log} $! -- Skipping!\n";

		if ( $fh ) {
			push( @global_instance_fhs, [ $instance, $fh ] );

			# tell the server instances that we've begun
			send_chat_msg($instance, undef, ( "AP ServerGuard, v:$app_version - Initialized." ) );
		}
	}
}

# tell the app log that we've begun
print_log("AP ServerGuard ($app_version) - Initialized.");

# set start time
my ( $last_sec, $last_min, $last_hr,
	$last_day, $last_mon, $last_yr ) = localtime(time());
	$last_mon += 1;
	$last_yr += 1900;

#
# MAIN LOOP
#

# Forever.
while (1) {
	# every pass
	my $loop_time = time;

	# Let the config change on the fly
	delete $INC{$config_file};
	require "$config_file";

	# Let this change on the fly too
	$global_pvp_mode_string = $pvp_modes{ $config->{pvp_mode} };
	$global_enf_modes_string = ( $config->{warn_users} ) ? "Warns, " : '';
	$global_enf_modes_string .= ( $config->{kick_users} ) ? "Kicks, " : '';
	$global_enf_modes_string .= ( $config->{ban_users} ) ? "Bans" : '';

	# Track this across restarts
	($global_infraction_map, $global_players_map, $mode_change_map, $victims_killers_map) = read_data_files();

	# Loop the instance logs' filehandles
	foreach my $tuple ( @global_instance_fhs ) {

		my ( $instance, $fh ) = @{ $tuple };

		# Ready for new lines
		select( $fh );

		while ( my $line = <$fh> ) {
			my ( $time, @rest_of_the_line ) = split / /, $line;
			next unless ( $time =~ m/$log_timestamp_regex/ );
			my( $y, $m, $d, $h, $min, $s ) = ( $1, $2, $3, $4, $5, $6 );

			if ( this_is_the_future($y,$m,$d,$h,$min,$s) ) {
				shift( @rest_of_the_line ); # ditch this element
				shift( @rest_of_the_line ); # and this one..

				# Re-assemble whats left of the line for matching
				my $message = join ' ', @rest_of_the_line;

				foreach my $handler ( @handler_map ) {
					if ( $message =~ /$handler->{match}/ ) {
						# Log that we have a match
						print_log("Handler: $handler->{name}");

						# Parent's PID
						$config->{ppid} = $$;

						# PARENT
						if ($config->{pid} = fork()) {
							push( @children, $config->{pid} );

						# CHILD
						} elsif (defined($config->{pid})) {

							# Process the message
							$handler->{method}->($instance, $loop_time, $message);

							# save
							#write_data_file($global_infraction_map, $global_players_map);
							write_data_files();

							# exit child
							exit(0);
						}
					}
				}

				# ignore this line if we got here
			}
		} # end while $fh

		# Clear EOF Flag
		seek( $fh, 0, 1 );

		# Announce for this Instance
		handle_announcements($instance, $loop_time);

	} # end foreach tuple

    # check up on our children
    for ( my $i = 0 ; $i < $#children ; $i ++ ) {
        my $child_status = undef;

        my $pid = waitpid($children[$i], WNOHANG);
        $child_status = $? / 256;

        if ($pid == $children[$i]) {
            # remove proc from list
            splice @children, $i, 1;
            my $msg .= "Child: $pid: exited with Status: $child_status";
			print_log($msg);
		}
	}

	# zombies
	while (my $zombie_pid = waitpid(-1, WNOHANG)) {
		if (-1 == $zombie_pid) { last; }
	}

	# ZzZz /* Snooze */
	sleep 1;

	# update the time on each pass, so we make sure
	# to catch any new lines in between nested passes

	# TODO: Maybe we *should* update the time again
	# at some point during the long haul

	#( $last_sec, $last_min, $last_hr,
	#$last_mon, $last_day, $last_yr ) = localtime(time());
	#$last_mon += 1;
	#$last_yr += 1900;
}

#
# EVENT HANDLER / TELNET FUNCTIONS
#

sub handle_announcements {
	#-------------
	my $instance = shift;
	my ($time) = @_;
	#-------------

	return unless ( $config->{do_announce} > 0 );

	foreach my $message ( keys %{ $config->{announcements} } ) {
		my $freq = $config->{announcements}->{$message};
		# frequency is in minutes, covert to seconds
		$freq *= 60;

		if ( $global_announce_map{"$message"} ) {
			my $last = $global_announce_map{"$message"};
			if ( $time >= ( $last + $freq ) ) {
				# time for a new notification
				send_chat_msg( $instance, undef, ( $message ) );
				$global_announce_map{"$message"} = $time;
			}
		} else {
			$global_announce_map{"$message"} = $time;
		}
	}
	
}

sub handle_chat_message {
	#-------------
	my $instance = shift;
	my ($time,$line) = @_;
	#-------------

	#$line =~ s/GMSG:\s?//;
	my($player_name,$message);

	if ( $line =~ m/GMSG: ([^:]+): (.+)$/ ) {
		$player_name = $1;
		$message = $2;
	}

	# skip our messages
	if ( $player_name eq 'Server' ) {
		return;
	}

	# player_name needs to match a real player
	my($player_id,$player_mode) = @{ $global_players_map->{$player_name} };

	# TODO: Colons in player_names
	return unless ( $player_id );

	if ( $config->{word_filter} > 0 ) {
		# check the message for banned words
		if ( grep { $message =~ /$_/i } @{ $config->{banned_words} } ) {
			# give them an infraction
			handle_infractions( $instance, $player_id, $player_name );
		}
	}

	if ( $message =~ /^\/\w+/ ) {
		# running a command
		handle_chat_command( $instance, $time, $player_name, $message );
	}
}

sub handle_chat_command {
	#-------------
	my $instance = shift;
	my ($time,$player_name,$command) = @_;
	#-------------

	my(@args);

	if ( $command =~ m![/]*([^\s]+)\s! ) {
		$command = $1;
	}

	return unless ( $player_name || $command );

	$command =~ s!/!!g;
	($command,@args) = split / /, $command;

	foreach my $c ( keys %command_map ) {
		if ($command eq $c) {
			$command_map{$c}->($instance, $time, $player_name, @args);
		}
	}
}

sub handle_deny_console_command {
	#-------------
	my $instance = shift;
	my ($time,$line) = @_;
	#-------------

	#Denying command 'command plus args' from client $PLAYER
	my($player_name,$command,@args);

	if ( $line =~ m/Denying command '([^']+)' from client (.+)$/ ) {
		$command = $1;
		$player_name = $2;
	}

	return unless ( $player_name || $command );

	$command =~ s!/!!g;
	($command,@args) = split / /, $command;

	foreach my $c ( keys %command_map ) {
		if ($command eq $c) {
			$command_map{$c}->($instance, $time, $player_name, @args);
		}
	}
	
}

sub handle_player_connected {
	#-------------
	my $instance = shift;
	my ($time,$line) = @_;
	#-------------

	my ($player_id, $player_name, $new_player);

	#Player connected, entityid=10899, name=Monkey Make!, steamid=76561197990553328, ip=104.175.223.46
	my @elems = split /, /, $line;

	foreach my $set ( @elems ) {
		my($key,$value) = split /=/, $set;
		if ( $key eq 'steamid' ) {
			$player_id = $value;
		} elsif ( $key eq 'name' ) {
			$player_name = $value;
		}
	}

	#print STDOUT "$player_id - $global_players_map->{$player_name}\n";

	unless ( exists $global_infraction_map->{$player_id} ) {
		$global_infraction_map->{$player_id} = 0;
		$new_player = 1;
	}
	unless ( exists $global_players_map->{"$player_name"} ) {
		$global_players_map->{"$player_name"} = [ $player_id, 0 ];
	}

	if ( $config->{welcome_players} ) {
		# send them a message or whatever.
		my @welcome_msg;

		if ( $new_player ) {
			@welcome_msg = @{ $config->{welcome_msg} };
			unless ( @welcome_msg ) {
				print_log( "config->welcome_msg missing..." );
				return;
			}

			$_ =~ s/%PLAYER%/$player_name/mg for ( @welcome_msg );
			$_ =~ s/%PVP_MODE%/$global_pvp_mode_string/mg for ( @welcome_msg );
			$_ =~ s/%ENF_MODES%/$global_enf_modes_string/mg for ( @welcome_msg );
		} else {
			@welcome_msg = ( "Welcome back, $player_name." );
		}

		send_player_pm( $instance, $player_id, $config->{welcome_msg_color}, @welcome_msg );
	}
}

sub handle_player_versus_player {
	#-------------
	my $instance = shift;
	my($time,$line) = @_;
	#-------------

	#Player $KILLER eliminated Player $VICTIM
	my($perp,$vic,$perp_ok);

	my @elems = split / /, $line;

	foreach my $elem ( @elems ) {
		next if ( $elem eq 'Player' );

		if ( $elem eq 'eliminated' ) {
			$perp_ok = 1;
		}

		unless ( $perp_ok ) {
			$perp .= $elem . " ";
		} else {
			$vic .= $elem . " ";
		}
	}

	$perp =~ s/\s?$//;
	$vic =~ s/\s?$//;

	# Now depends on PVP Mode
	for ( $config->{pvp_mode} ) {
		# Full PVP
		if ( 0 ) {
			# maybe do something later

		# Pure PVE
		} elsif ( 1 ) {
			handle_pure_pve_mode( $instance, $time, $perp, $vic );
		# Hybrid PVP/PVE
		} elsif ( 2 ) {
			handle_hybrid_pvp_mode( $instance, $time, $perp, $vic );
		} else {
			# do nothing here
		}
	}

}

#
# SUB-HANDLERS
#

sub handle_hybrid_pvp_mode {
	my $instance = shift;
	my($time,$perp,$vic) = @_;

	my ($perp_id,$perp_mode) = $global_players_map->{"$perp"};
	my ($vic_id,$vic_mode) = $global_players_map->{"$vic"};

	unless ( $vic_mode > 0 ) {
		# store their killer for reporting on
		$victims_killers_map->{$vic_id} = $perp;

		# vic is not pvp toggled, ask them to /report
		send_player_pm( $instance, $vic_id, $config->{warn_color}, ("You have been killed by $perp.", "Type /report if you wish to report this.") );
	}

	unless ( $perp_mode > 0 ) {
		# perp is not pvp toggled, toggle them
		$global_players_map->{"$perp"} = [ $perp_id, 1 ];

		# log the time of this mode change
		$mode_change_map->{$perp_id} = $time;

		send_player_pm( $instance, $perp_id, $config->{warn_color}, ("You are now toggled for PVP for killing $vic."));
	}
}

sub handle_pure_pve_mode {
	my $instance = shift;
	my($time,$perp,$vic) = @_;

	my ($perp_id) = $global_players_map->{"$perp"};
	my ($vic_id) = $global_players_map->{"$vic"};

	# give them an infraction
	handle_infractions( $instance, $perp_id, $perp );
}

sub handle_infractions {
	my $instance = shift;
	my($perp_id,$perp) = @_;

	my @msg;
	my $perp_inf = ++$global_infraction_map->{$perp_id};

	if ( $config->{ban_users} > 0 ) {
		unless ( $config->{ban_after} > $perp_inf ) {
			# Perp gets a Ban
			my $base_duration = $config->{ban_duration};
			my $ban_multiply = $config->{ban_mulitplier};
			my $next_delta = ( $config->{ban_after} - $perp_inf );
			$ban_multiply *= $next_delta;

			# ban_multiply ends up 0 here on the first ban, set it to base_duration
			my $ban_duration = ( $ban_multiply ) ? $ban_multiply * $base_duration : $base_duration;
			# don't multiply by 0, use the original multiplier value
			my $next_ban = $ban_duration * $config->{ban_multiplier};

			my $a = "Your next infraction ban will be for $next_ban minutes.";

			@msg = @{ $config->{ban_msg} };
			$_ =~ s/%PLAYER%/$perp/mg for ( @msg );
			$_ =~ s/%DURATION%/$ban_duration/mg for ( @msg );
			$_ =~ s/%INF_COUNT%/$perp_inf/mg for ( @msg );
			$_ =~ s/%ENF_MODES%/$global_enf_modes_string/mg for ( @msg );
			$_ =~ s/%MORE_INF%/$a/mg for ( @msg );

			send_player_pm( $instance, $perp_id, $config->{warn_msg_color}, @msg );

			sleep 10;

			my $msg = "AP: $perp_inf Rule Infractions.";
			handle_telnet_command($instance, 'ban add ' . $perp_id . ' ' . $ban_duration . ' minutes \"' . $msg . '\"');
		}
	}
	if ( $config->{kick_users} > 0 ) {
		unless ( $config->{kick_after} > $perp_inf ) {
			# Perp gets a Kick
			my $next_delta = ( $config->{ban_after} - $perp_inf );

			@msg = @{ $config->{kick_msg} };
			$_ =~ s/%PLAYER%/$perp/mg for ( @msg );
			$_ =~ s/%INF_COUNT%/$perp_inf/mg for ( @msg );
			$_ =~ s/%ENF_MODES%/$global_enf_modes_string/mg for ( @msg );

			if ( $config->{ban_users} > 0 ) {
				my $a = "You will be banned after $next_delta more infractions.";
				$_ =~ s/%MORE_INF%/$a/mg for ( @msg );
			} else {
				$_ =~ s/%MORE_INF%//mg for ( @msg );
			}

			send_player_pm( $instance, $perp_id, $config->{warn_msg_color}, @msg );

			sleep 10;

			my $msg = "AP: $perp_inf Rule Infractions.";
			handle_telnet_command($instance, 'kick ' . $perp_id . '\"' . $msg . '\"');
		}
	}
	if ( $config->{warn_users} > 0 ) {
		unless ( $config->{warn_after} > $perp_inf ) {
			# Perp gets a Warning

			my $next_delta = ( $config->{kick_after} - $perp_inf );

			@msg = @{ $config->{warn_msg} };
			$_ =~ s/%PLAYER%/$perp/mg for ( @msg );
			$_ =~ s/%INF_COUNT%/$perp_inf/mg for ( @msg );
			$_ =~ s/%ENF_MODES%/$global_enf_modes_string/mg for ( @msg );

			if ( $config->{kick_users} > 0 ) {
				my $a = "You will be kicked after $next_delta more infractions.";
				$_ =~ s/%MORE_INF%/$a/mg for ( @msg );
			} else {
				$_ =~ s/%MORE_INF%//mg for ( @msg );
			}

			send_player_pm( $instance, $perp_id, $config->{warn_msg_color}, @msg );
		}
	}

}

#
# CHAT COMMANDS
#

sub handle_help_command {
	my $instance = shift;
	my($time, $player_name, @args) = @_;

	my($player_id) = @{ $global_players_map->{$player_name} };

	return unless ( $player_id );

	my @msg = (
		'* AP ServerGuard Command Help:',
		'  /pvp     - Toggle PVP mode on and off.',
		'  /report  - Report unwated PVP action to infract your killer.',
		'  /help    - This usage menu. :)'
	);

	send_player_pm( $instance, $player_id, undef, @msg );
}

sub handle_pvp_command {
	my $instance = shift;
	my($time, $player_name, @args) = @_;

	my($player_id, $pvp_mode) = @{ $global_players_map->{$player_name} };

	my $msg;

	# 1 = Pure PVE
	if ( $config->{pvp_mode} != 1 ) {
		if ( $pvp_mode == 0 ) {
			# log the time of this mode change
			$mode_change_map->{$player_id} = $time;
			$global_players_map->{"$player_name"} = [ $player_id, 1 ];
			$msg = "PVP mode ENABLED.";
		} elsif ( $pvp_mode == 1 ) {
			# get last mode change time
			my $last = $mode_change_map->{$player_id};
			my $delta = ( $config->{pvp_cooldown} * 60 ) - ( $time - $last );

			# if enough time has passed
			if ( $time > ( $last + ( $config->{pvp_cooldown} * 60 ) ) ) {
				$mode_change_map->{$player_id} = 0;
				$global_players_map->{"$player_name"} = [ $player_id, 0 ];
				$msg = "PVP mode DISABLED.";
			} else {
				$msg = "You must wait $delta seconds to disable PVP mode.";
			}
		}
	} else {
		$msg = "Sorry, you cannot toggle PVP in Pure PVE mode.";
	}

	send_player_pm( $instance, $player_id, $config->{warn_color}, ( $msg ) );
}

sub handle_report_command {
	my $instance = shift;
	my($time, $player_name, @args) = @_;

	my($player_id, $pvp_mode) = @{ $global_players_map->{$player_name} };

	my $msg;

	# 0 = Full PVP
	if ( $config->{pvp_mode} != 0 ) {
		if ( $pvp_mode == 0 ) {
			if ( exists $victims_killers_map->{$player_id} ) {
				my $perp = $victims_killers_map->{$player_id};
				my($perp_id) = $global_players_map->{$perp};

				# give them an infraction
				handle_infractions( $instance, $perp_id, $perp );

				$msg = "Thank you for the report, action has been taken.";
			} else {
				$msg = "Sorry, there is no record of your killer.";
			}
		} else {
			$msg = "Sorry, you cannot report your killer while toggled for PVP.";
		}
	} else {
		$msg = "Sorry, you cannot report your killer in Full PVP mode.";
	}

	send_player_pm( $instance, $player_id, $config->{warn_color}, ( $msg ) );
}

#
# LOW-LEVEL COMMS
#

sub handle_telnet_command {
	my $instance = shift;
	my($command) = @_;

	return unless ( $instance );
	return unless ( $command );
	return unless ( -e $config->{telnet_cmd} );

	my $safer_password = $instance->{telnet_pass};
	$safer_password =~ s/([!;\$])/\\$1/g;

	my @command_options = (
		$instance->{telnet_host},
		$instance->{telnet_port},
		$safer_password,
		"$command",
	);

	#system( $config->{telnet_cmd}, @command_options );
	#open ( CMD, "-|", $config->{telnet_cmd}, @command_options );
	open ( CMD, "-|", $config->{telnet_cmd}, @command_options );
	close ( CMD );
}

sub send_chat_msg {
	my $instance = shift;
	my($color, @message) = @_;

	$color = $config->{general_msg_color} unless ( $color );
	$color = '\[' . $color . '\]';
	my $end_color = $config->{default_chat_color};
	$end_color = '\[' . $end_color . '\]';

	foreach my $msg ( @message ) {
		next unless ( $msg );
		$msg =~ s/([!;\$]+)/\\$1/g;
		handle_telnet_command(
			$instance,
			'say \"' . $color . $msg . $end_color . '\"'
		);
		sleep 1;
	}
}

sub send_player_pm {
	my $instance = shift;
	my ($player_id,$color,@message) = @_;

	$color = $config->{general_msg_color} unless ( $color );
	$color = '\[' . $color . '\]';
	my $end_color = $config->{default_chat_color};
	$end_color = '\[' . $end_color . '\]';

	foreach my $msg ( @message ) {
		next unless ( $msg );
		$msg =~ s/([!;\$]+)/\\$1/g;
		print STDOUT 'pm ' . $player_id . ' \"' . $color . $msg . $end_color . '\"' . "\n";
		handle_telnet_command(
			$instance,
			'pm ' . $player_id . ' \"' . $color . $msg . $end_color . '\"'
		);
		sleep 1;
	}
}

#
# APP FUNCTIONS
#

sub get_app_version {
	my $version = `cat VERSION`;
	chomp $version;
	return $version;
}

sub get_current_date {
    my @months = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
    my @fields = localtime(time());
    my $datestr =
        # day of month
        sprintf("%02i", $fields[3]) .
        '/' .
        # name of month
        $months[$fields[4]] .
        '/' .
        # year
        ($fields[5]+1900) .
        ':' .
        # hours (24 hour clock)
        sprintf("%02i", $fields[2]) .
        ':' .
        # minutes
        sprintf("%02i", $fields[1]) .
        ':' .
        # seconds
        sprintf("%02i", $fields[0]);
    return ($datestr);
}

sub quit {
    my $str = shift(@_);

    print STDERR "EXIT: ";
    if ($str) {
        print STDERR $str;
    }
    print STDERR "\n";

    # write to log file
    print_log("EXIT: $str");

	# close all the filehandles now
	foreach my $tuple ( @global_instance_fhs ) {
		my ( $instance, $fh ) = @{ $tuple };
		close( $fh );
	}

    # check up on our children
    for ( my $i = 0 ; $i < $#children ; $i ++ ) {
        my $child_status = undef;

        my $pid = waitpid($children[$i], WNOHANG);
        $child_status = $? / 256;

        if ($pid == $children[$i]) {
            # remove proc from list
            splice @children, $i, 1;
            my $msg .= "Child: $pid: exited with Status: $child_status";
			print_log($msg);
		}
	}

	# zombies
	while (my $zombie_pid = waitpid(-1, WNOHANG)) {
		if (-1 == $zombie_pid) { last; }
	}

    # remove lockfile
    if ($config->{pid_file}) {
        unlink($config->{pid_file});
    }

    exit(1);
}

sub print_log {
    my $str = shift(@_);
    chomp $str;

    my $log_string = '';
    my $result = undef;

    $log_string .= '[';
    $log_string .= get_current_date();
    $log_string .= '] ';
    if ($str) {
        $log_string .= $str;
    }
    $log_string .= "\n";

    open(LOG, ">> $config->{log_file}");
	#select(LOG);
    print LOG $log_string;
    close(LOG);
}

sub read_data_files {
	my $main = $config->{main_data_file};
	my $mode = $config->{mode_data_file};
	my $kill = $config->{kill_data_file};

	# infraction, players, mode_time, murders
	my (%map1,%map2,%map3,%map4);

	return ({}, {}, {}, {}) unless ( $main || $mode || $kill );

	unless ( -e $main ) {
		open ( DATA, ">", $main ) or quit("Could not create data file $main $!");
		close( DATA );
	}

	unless ( -e $mode ) {
		open ( DATA, ">", $mode ) or quit("Could not create data file $mode $!");
		close( DATA );
	}

	unless ( -e $kill ) {
		open ( DATA, ">", $kill ) or quit("Could not create data file $kill $!");
		close( DATA );
	}

	my @lines;

	open ( DATA, "<", $main ) or quit("Could not read data file $main $!");
		@lines = <DATA>;
	close ( DATA );

	foreach my $line ( @lines ) {
		chomp $line;
		my($id,$name,$inf,$mode) = split /\t/, $line;
		$map1{$id} = $inf;
		$map2{"$name"} = [ $id, $mode ];
	}

	open ( DATA, "<", $mode ) or quit("Could not read data file $mode $!");
		@lines = <DATA>;
	close ( DATA );

	foreach my $line ( @lines ) {
		chomp $line;
		my($id,$time) = split /\t/, $line;
		$map3{$id} = $time;
	}

	open ( DATA, "<", $kill ) or quit("Could not read data file $kill $!");
		@lines = <DATA>;
	close ( DATA );

	foreach my $line ( @lines ) {
		chomp $line;
		my($id,$name) = split /\t/, $line;
		$map4{$id} = $name;
	}

	return (\%map1,\%map2,\%map3,\%map4);
}

sub this_is_the_future {
	my ($y,$m,$d,$h,$min,$s ) = @_;

	if ( $y >= $last_yr &&
		$m >= $last_mon &&
			(( $d == $last_day && $h == $last_hr && $min >= $last_min) ||
			#(( $d == $last_day && $h >= $last_hr ) || # testing
			( $d == $last_day && $h > $last_hr) ||
				$d > $last_day ) ) {
			return 1;
		}
}

sub write_data_files {
	#my($global_infraction_map, $global_players_map) = @_;
	my $main = $config->{main_data_file};
	my $mode = $config->{mode_data_file};
	my $kill = $config->{kill_data_file};

	return unless ( $main || $mode || $kill );

	# main data
	open ( DATA, ">", $main ) or quit("Could not write data file $main $!");
	foreach my $name ( keys %{ $global_players_map } ) {
		my ($id,$mode) = @{ $global_players_map->{$name} };
		my $inf = $global_infraction_map->{$id};
		print DATA $id . "\t" . $name . "\t" . $inf . "\t" . $mode . "\n";
	}
	close( DATA );

	# mode changes
	open ( DATA, ">", $mode ) or quit("Could not write data file $mode $!");
	while ( my ($id,$time) = each %{ $mode_change_map } ) {
		print DATA $id . "\t" . $time . "\n";
	}
	close( DATA );

	# murderees -> murderers
	open ( DATA, ">", $kill ) or quit("Could not write data file $kill $!");
	while ( my ($id,$name) = each %{ $victims_killers_map } ) {
		print DATA $id . "\t" . $name . "\n";
	}
	close( DATA );

	# seems like it worked
	return 1;
}

sub write_pid_file {
    my $pid_file = $config->{pid_file};

    # if the pid file exists, perhaps another instance of this is running already
    if ( -e $pid_file ) {
        open(PID_FILE, $pid_file);
        my $pid_from_file = <PID_FILE>;
        close(PID_FILE);

        chomp($pid_from_file);

        if ($pid_from_file =~ m/^\d+$/o) {
            my $result = kill(0, $pid_from_file);
            if ($result) {
                print STDERR "Another instance of $app_name is already running with PID file $pid_file\n";
                exit(1);
            }
        }
    }

    # write the pid file
    open(PID_FILE, "> $pid_file");
    print PID_FILE $$, "\n";
    close(PID_FILE);
}

sub usage {
	die "Usage: $0 [OPTIONS]

	[OPTIONS]

	-c          [Optional] Custom config path
	-daemon     Run as a service.
	-help       This usage menu.

	\n";
}
