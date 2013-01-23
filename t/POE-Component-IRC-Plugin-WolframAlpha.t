use strict;
use warnings;

use Test::More tests => 14;

use POE;
use POE::Component::IRC;
use POE::Component::Server::IRC;

use constant {
    APP_ID => 'LY4T94-KEWR56TEHX',
};

BEGIN { use_ok('POE::Component::IRC::Plugin::WolframAlpha') };

my $bot = POE::Component::IRC->spawn(
    plugin_debug => 1 ,
    Flood        => 1,
);

my $ircd = POE::Component::Server::IRC->spawn(
    AntiFlood => 0,
    Auth      => 0,
);

POE::Session->create(
    package_states => [
        main => [qw(
            _start 
            irc_plugin_add 
            irc_plugin_del
            irc_001
            irc_join
            ircd_listener_add
            ircd_listener_failure
            ircd_daemon_public
            got_result
            _shutdown
        )],
    ],
);

POE::Kernel->run();

sub _start {
    my ($kernel) = @_[KERNEL];

    $ircd->yield(register => 'all');
    $ircd->yield('add_listener');
    $kernel->delay(_shutdown => 100, 'Timed out');
}

sub irc_plugin_add {
    my ($alias, $plugin, $kernel) = @_[KERNEL, ARG0, ARG1, KERNEL];
    return if $alias ne 'TestPlugin';
    isa_ok($plugin, 'POE::Component::IRC::Plugin::WolframAlpha');
}

sub irc_plugin_del {
    my ($kernel, $alias, $plugin) = @_[KERNEL, ARG0, ARG1];
    return if $alias ne 'TestPlugin';

    isa_ok($plugin, 'POE::Component::IRC::Plugin::WolframAlpha');
}

# IRCD spawned, connect our bot
sub ircd_listener_add {
    my ($kernel, $port) = @_[KERNEL, ARG0];

    $bot->yield(register => 'all');
    $ircd->yield('add_spoofed_nick', {nick => 'OperServ'});
    $ircd->yield('daemon_cmd_join','OperServ', '#testchannel');

    my $plugin = new_ok('POE::Component::IRC::Plugin::WolframAlpha', [appid => APP_ID]);
    if (!$bot->plugin_add(TestPlugin => $plugin)) {
        $kernel->yield('_shutdown', 'plugin_add_failed');
    }
    $bot->yield(connect => { 
        nick   => 'TestBot',
        server => '127.0.0.1',
        port   => $port,
    });
}

sub ircd_listener_failure {
    my ($kernel, $op, $reason) = @_[KERNEL, ARG0, ARG1];
    $kernel->yield('_shutdown', "$op: $reason");
}

# Bot connected
sub irc_001 {
    pass('Connected');
    $bot->yield(join => '#testchannel');
}

# Bot joined
sub irc_join {
    my ($kernel, $where) = @_[KERNEL, ARG1];
    pass('Joined channel');

    $kernel->yield('wolfram_req', { input => "age of jaromir jagr", 
                                    channel => $where });

    $kernel->yield('wolfram_req', { input => "age of ivan gasparovic",
                                    channel => $where,
                                    oevent => 'got_result', quiet => 1 });
}

my $msgc = 0;
my $eventc = 0;

sub got_result {
    my ($kernel, $res) = @_[KERNEL, ARG0];

    is($res->{request}, 'age of ivan gasparovic');
    ok(exists $res->{pods});
    pass("Output event");
    $eventc++;
    $kernel->yield('_shutdown') if ($eventc == 3);
}

sub ircd_daemon_public {
    my ($kernel, $nick, $channel, $msg) = @_[KERNEL, ARG0, ARG1, ARG2];
    like($nick, qr/TestBot/);
    is($channel, '#testchannel');

    if (!$msgc) {
        if ($msg =~ /(\d+):.*result.*/) {
            pass('result printed into channel');
            $kernel->yield('wolfram_display_pod', $channel, 'result', $1);
        }
    }
    else {
        like($msg, qr/years/);
    }

    $msgc++;
    $eventc++;
    $kernel->yield('_shutdown') if ($eventc == 3);
}

sub _shutdown {
    my ($kernel, $error) = @_[KERNEL, ARG0];
    fail($error) if defined $error;

    $kernel->alarm_remove_all();
    $ircd->yield('shutdown');
    $bot->yield('shutdown');
}

#sub _default {
#    my ($event, $args) = @_[ARG0 .. $#_];
#    my @output = ( "$event: " );
# 
#    for my $arg (@$args) {
#        if ( ref $arg eq 'ARRAY' ) {
#            push( @output, '[' . join(', ', @$arg ) . ']' );
#        }
#        else {
#            push ( @output, "'$arg'" );
#        }
#    }
#    #diag join ' ', @output, "\n";
#    return;
#}
#done_testing;
