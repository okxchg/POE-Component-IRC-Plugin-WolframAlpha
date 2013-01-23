package POE::Component::IRC::Plugin::WolframAlpha;

use strict;
use warnings;

use Carp;
use POE;
use POE::Kernel;
use POE::Component::IRC::Plugin qw( :ALL );
use WWW::WolframAlpha;
use POE::Quickie;
use List::MoreUtils qw( any none );
use JSON qw( decode_json encode_json );

our $VERSION = 0.1;

sub new {
    my ($class, %args) = @_;
    my $self = {};

    $self->{appid}           = delete $args{appid};
    $self->{cache_size}      = delete $args{cache_size} || 30;
    $self->{max_concurrency} = delete $args{max_concurrency} || 5;
    $self->{cur_concurrency} = 0;
    $self->{cache}           = [];

    croak 'No appid specified' if not defined $self->{appid};
    bless $self, $class;
}

sub PCI_register {
    my ($self, $irc) = @_;

    $self->{irc} = $irc;
    $self->{wa} = WWW::WolframAlpha->new(
        appid => $self->{appid},
    );
    POE::Kernel->state('wolfram_req', $self);
    POE::Kernel->state('wolfram_display_pod', $self);
    POE::Kernel->state('wolfram_dump_cache', $self);

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start 
                _sig_DIE
                _got_wa_result 
                _wa_request 
                _wa_display_pod
                _wa_dump_cache
            )]
        ]
    );
    return 1;
}

sub _start {
    $_[KERNEL]->alias_set('wa_session');
    $_[KERNEL]->sig(DIE => '_sig_DIE');
}

sub _sig_DIE {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];

    chomp $ex->{error_str};
    warn "Error: Event $ex->{event} in $ex->{dest_session} raised exception:\n";
    warn "  $ex->{error_str}\n";
    $kernel->sig_handled();
    return;
}

sub wolfram_req {
    my $req = $_[ARG0];

    $req->{sender} = $_[SENDER]->ID();
    $_[KERNEL]->post('wa_session', _wa_request => $req);
}

sub wolfram_display_pod {
    $_[KERNEL]->post('wa_session', '_wa_display_pod', 
        @_[ARG0, ARG1, ARG2, ARG3]);
}

sub wolfram_dump_cache {
    $_[KERNEL]->post('wa_session', '_wa_dump_cache', $_[ARG0]);
}

sub _wa_dump_cache {
    my ($self, $nick) = @_[0, ARG0];

    for (0 .. $#{ $self->{cache} }) {
        $self->_dump_cache_entry($_, $nick, $self->{cache}[$_]);
    }
}

sub _dump_cache_entry {
    my ($self, $c, $chan, $entry) = @_;

    $self->_privmsg($chan => "#$c:$entry->{request}:".
        join ',', keys %{ $entry->{pods} });
}

sub _wa_request {
    my ($self, $req) = @_[0, ARG0];

    $req->{input} =~ s/^\s+//g;
    $req->{input} =~ s/\s+$//g;

    for (0 .. $#{ $self->{cache} }) {
        if ($self->{cache}[$_]{request} eq $req->{input}) {
            $self->_dump_cache_entry($_, $req->{channel}, $self->{cache}[$_]);
            return;
        }
    }

    if ($self->{cur_concurrency} == $self->{max_concurrency}) {
        $self->_privmsg($req->{channel}, 'Concurrency maximum reached');
        return;
    }
    $self->{cur_concurrency}++;

    POE::Quickie->run(
        Context     => $req,
        ResultEvent => '_got_wa_result',
        Program     => sub {
            $self->_send_wa_query($req);
        },
    );
}

my %formaters = (
    img => sub {
        (split /'/, shift)[5];
    },

    plaintext => sub {
        shift; 
    }
);

sub _wa_display_pod {
    my ($self, $channel, $title, $id, $type) = @_[0, ARG0, ARG1, ARG2, ARG3];

    $id = $#{ $self->{cache} } if not defined $id;
    $type = 'plaintext'        if not defined $type;

    return $self->_privmsg($channel => "unkown type $type") 
        if none { $_ eq $type } qw( plaintext img );

    return $self->_privmsg($channel => "Unkown result id $id.") 
        if $id !~ /\d+/ || not defined $self->{cache}[$id];

    return $self->_privmsg($channel => "No pod $title in result #$id") 
        if not defined $self->{cache}[$id]{pods}{ $title };

    my $got = 0;
    foreach my $subpod (@{ $self->{cache}[$id]{pods}{ $title } }) {
        if (defined $subpod->{ $type }) {
            my $output = $formaters{ $type }->($subpod->{ $type });

            $self->_privmsg($channel => $_)
                for (split /\n/, $output) ;

            $got = 1;
        }
    }
    $self->_privmsg($channel => "No $type subpods in result #$id") if !$got;
}

sub _send_wa_query {
    my ($self, $req) = @_;

    my $query = $self->{wa}->query(
        'scantimeout' => 5,
        'podtimeout'  => 5,
        'format'      => 'plaintext,image',
        'input'       => $req->{input},
    );

    if ($query->success) {
        my %pods;

        for my $pod (@{ $query->pods }) {
            next if $pod->error;

            (my $title = lc $pod->title) =~ s/\s+/_/g;
            $pods{$title} = [];

            my $i = 0;
            for my $subpod (@{ $pod->subpods }) {
                $pods{ $title }[$i]{plaintext} = $subpod->plaintext;
                $pods{ $title }[$i]{img}       = $subpod->img;
                $pods{ $title }[$i]{title}     = $subpod->title;
                $i++;
            }
        }
        print STDERR encode_json \%pods, "\n";
        print join ', ', keys %pods;
        print "\n";
    }
    elsif (!$query->error) {
        print "No results.";

        if ($query->didyoumeans->count) {
            print " Did you mean: ", 
                join ';', @{ $query->didyoumeans->didyoumean };
        }
        print "\n";
    } 
    elsif ($self->{wa}->error) {
        print STDERR "WWW::WolframAlpha error: ", $self->{wa}->errmsg , "\n" 
            if $self->{wa}->errmsg;
        return 1;
    } 
    elsif ($query->error) {
        print STDERR "WA error ", $query->error->code, ": ", $query->error->msg, "\n";
        return 1;
    }
    return 0;
}

sub _got_wa_result {
    my ($self, $kernel, $stdout_chunks, $stderr_chunks, $ret, $req) = 
        @_[0, KERNEL, ARG1, ARG2, ARG4, ARG5];

    # ret = 0, successful query
    if (!$ret) {
        if (!$stdout_chunks) {
            my $error = 'Something went wrong and we have no pods but query was succesfull';
            $kernel->post($req->{sender}, $req->{oevent}, {
                    request => $req->{input},
                    pods    => undef,
                    error   => $error,
            }) if ($req->{oevent});

            $self->_privmsg($req->{channel}, $error) if (!$req->{quiet});
            return; 
        }

        my $stdout = "@{ $stdout_chunks }";

        # json data are on stderr, channel output on stdout
        if ($stderr_chunks) {
            shift @{ $self->{cache} } 
                if (@{ $self->{cache} } == $self->{cache_size});

            push @{ $self->{cache} }, {
                    request => $req->{input},
                    pods    => decode_json "@{ $stderr_chunks}"
                };
                
            $kernel->post($req->{sender}, $req->{oevent}, $self->{cache}[-1])
                if ($req->{oevent});
        }
        else {
            $kernel->post($req->{sender}, $req->{oevent}, {request => $req->{input}, pods => undef}) 
                if ($req->{oevent});
        }

        $self->_privmsg($req->{channel}, (@{ $self->{cache} }-1).':'.$stdout)
            if (!$req->{quiet});

    }
    else {
        $self->_privmsg($req->{channel} => 
            "Wolfram query process failed @{ $stderr_chunks}")
            if (!$req->{quiet});

        $kernel->post($req->{sender}, $req->{oevent}, {
                request => $req->{input},
                error   => "@{ $stderr_chunks }",
                pods    => undef
        }) if ($req->{oevent});
    }
}

sub PCI_unregister {
    return 1;
}

sub appid {
    return (shift)->{appid};
}

sub cache_size {
    my ($self, $size) = @_;
    $self->{cache_size} = $size if ($size);
    return $self->{cache_size};
}
    
sub max_concurrency {
    my ($self, $mc) = @_;
    $self->{max_concurrency} = $mc if ($mc);
    return $self->{max_concurrency};
}

sub _privmsg {
    my ($self, $channel, $msg) = @_;

    $self->{irc}->yield(privmsg => $channel => $msg);
}
1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

POE::Component::IRC::Plugin::WolframAlpha - Request WolframAlpha database from irc bot

=head1 SYNOPSIS

    use POE;
    use POE::Component::IRC;
    use POE::Component::IRC::Plugin::BotCommand;
    use POE::Component::IRC::Plugin::WolframAlpha;
     
    my $irc = POE::Component::IRC->spawn(
        nick   => 'wabot',
        server => 'irc.freenode.net',
    );
     
    POE::Session->create(
        package_states => [
            main => [ qw(_start irc_001 irc_botcmd_wa irc_botcmd_war irc_botcmd_dump) ],
        ],
    );
     
    $poe_kernel->run();
     
    sub _start {
        $irc->plugin_add('BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
            Commands => {
                wa   => 'Request wolframalpha',
                war  => 'Display results from previous wa requests (args title id type)',
                dump => 'Dump request cache im pm',
            }
        ));
        $irc->plugin_add('WolframAlpha', POE::Component::IRC::Plugin::WolframAlpha->new(
                appid => 'LY4T94-KEWR56TEHX'
        ));
        $irc->yield(register => 'all');
        $irc->yield(connect => { });
    }
     
    sub irc_001 {
        $irc->yield(join => '#wabottest');
        return;
    }
     
    sub irc_botcmd_wa {
        my ($kernel, $nick, $channel, $req) = @_[KERNEL, ARG0, ARG1, ARG2];

        $kernel->yield(wolfram_req => {channel => $channel, input => $req});
    }

    sub irc_botcmd_war {
        my ($kernel, $nick, $channel, $req) = @_[KERNEL, ARG0, ARG1, ARG2];

        $kernel->yield(wolfram_display_pod => $channel, split /\s/, $req);
    }

    sub irc_botcmd_dump {
        my ($kernel, $nick, $channel, $req) = @_[KERNEL, ARG0, ARG1, ARG2];

        ($nick) = split /!/, $nick;
        $kernel->yield(wolfram_dump_cache => $nick);
    }

=head1 DESCRIPTION

This plugins allows you to asynchronously make wolframalpha requests from your
IRC bot by sending POE events.

=head2 METHODS

=over

=item B<new>

Create new plugin object. Arguments:

=over

=item I<cache_size>

Control cache size, default is 30.

=item I<max_concurrency>

How many requests can be running simulatenously.

=item I<appid>

Mandatory. Specify your WolframAlpha application id.

=back

=item B<cache_size>

    Get/set cache_size.

=item B<max_concurrency>

    Get/set max_concurrency

=item B<appid>

    Get appid.

=back

=head1 INPUT EVENTS

=over 

=item B<wolfram_req>

Request WolframAlpha database. Results are stored in internal cache
and list of avalaible pods (see WWW::WolframAlpha or WA api documentation) is
returned into the channel.

ARG0 is a hash reference which can have following keys:
    'request': text of the request, this is mandatory
    'channel': channel where to send result of request, mandatory if quiet is not set
    'quiet'  : don't dump anything into channel
    'oevent' : send this event to current session when request is done

Output event recieves hash in ARG0 like this:
    'request': original request
    'pods'   : hash reference with pod title as keys and array of subpods as
               values, can be undef if there was no results or an error 
    'error'  : set to error message if there was an error

=item B<wolfram_display_pod>

Display pod from cache in channel. ARG0 is title of pod, ARG1 can contain id of
a result (or the last result is selected), ARG2 can contain type of information
requested (currently plaintext or img are supported). 

=item B<wolfram_dump>

Dump contents of result cache into channel. ARG0 is channel name.

=back

=head1 SEE ALSO

M<POE::Component::IRC::Plugin> M<POE::Component::IRC>
=head1 AUTHOR

Oliver Kindernay, E<lt>oliver.kindernay@gmail.cmm<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Oliver Kindernay

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.12.3 or,
at your option, any later version of Perl 5 you may have available.


=cut
