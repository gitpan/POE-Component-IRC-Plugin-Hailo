package POE::Component::IRC::Plugin::Hailo;

use strict;
use warnings;
use Carp;
use POE;
use POE::Component::Hailo;
use POE::Component::IRC::Common qw(l_irc matches_mask_array irc_to_utf8 strip_color strip_formatting);
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);

our $VERSION = '0.06';

sub new {
    my ($package, %args) = @_;
    my $self = bless \%args, $package;

    if (ref $self->{Hailo} eq 'POE::Component::Hailo') {
        $self->{keep_alive} = 1;
    }
    else {
        $self->{Hailo} = POE::Component::Hailo->spawn(
            Hailo_args => $self->{Hailo_args},
        );
    }

    $self->{Method} = 'notice' if !defined $self->{Method} || $self->{Method} !~ /privmsg|notice/;
    $self->{abusers} = { };
    $self->{Abuse_interval} = 60 if !defined $self->{Abuse_interval};

    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;

    if (!$irc->isa('POE::Component::IRC::State')) {
        die __PACKAGE__ . " requires PoCo::IRC::State or a subclass thereof\n";
    }

    $self->{irc} = $irc;
    POE::Session->create(
        object_states => [
            $self => [qw(_start _sig_DIE hailo_learn_replied _msg_handler)],
        ],
    );

    $irc->plugin_register($self, 'SERVER', qw(isupport ctcp_action public));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;

    $irc->yield(part => $self->{Own_channel}) if $self->{Own_channel};
    delete $self->{irc};
    $poe_kernel->post($self->{Hailo}->session_id() => 'shutdown') unless $self->{keep_alive};
    delete $self->{Hailo};
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $self, $session) = @_[KERNEL, OBJECT, SESSION];
    $kernel->sig(DIE => '_sig_DIE');
    $self->{session_id} = $session->ID();
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub _sig_DIE {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
    chomp $ex->{error_str};
    warn "Error: Event $ex->{event} in $ex->{dest_session} raised exception:\n";
    warn "  $ex->{error_str}\n";
    $kernel->sig_handled();
    return;
}

sub hailo_learn_replied {
    my ($self, $args, $context) = @_[OBJECT, ARG0, ARG1];
    my $reply = shift @$args;
    $reply = "I don't know enough to answer you yet." if !defined $reply;
    
    $self->{irc}->yield($self->{Method} => $context->{_target}, $reply);
    return;
}

sub _ignoring_user {
    my ($self, $user) = @_;
    
    if ($self->{Ignore_masks}) {
        my $mapping = $self->{irc}->isupport('CASEMAPPING');
        return 1 if keys %{ matches_mask_array($self->{Ignore_masks}, [$user], $mapping) };
    }

    return;
}

sub _ignoring_abuser {
    my ($self, $user, $chan) = @_;

    my $key = "$user $chan";
    my $last_time = delete $self->{abusers}->{$key};
    $self->{abusers}->{$key} = time;

    return 1 if $last_time && (time - $last_time < $self->{Abuse_interval});
    return;
}

sub _msg_handler {
    my ($self, $kernel, $type, $user, $chan, $what) = @_[OBJECT, KERNEL, ARG0..$#_];
    my $nick = $self->{irc}->nick_name();

    return if $self->_ignoring_user($user);
    $what = _normalize_irc($what);

    # should we reply?
    my $event = 'learn';
    if ($self->{Own_channel} && (l_irc($chan) eq l_irc($self->{Own_channel}))
        || $type eq 'public' && $what =~ s/^\s*\Q$nick\E[:,;.!?~]?\s//i
        || $self->{Talkative} && $what =~ /\Q$nick/i)
    {
        $event = 'learn_reply';
    }

    if ($event eq 'learn_reply' && $self->_ignoring_abuser($user, $chan)) {
        $event = 'learn';
    }

    if ($self->{Ignore_regexes}) {
        for my $regex (@{ $self->{Ignore_regexes} }) {
            return if $what =~ $regex;
        }
    }

    $kernel->post(
        $self->{Hailo}->session_id(),
        $event,
        [$what],
        {_target => $chan },
    );

    return;
}

sub _normalize_irc {
    my ($line) = @_;

    $line = irc_to_utf8($line);
    $line = strip_color($line);
    $line = strip_formatting($line);
    return $line;
}

sub brain {
    my ($self) = @_;
    return $self->{Hailo};
}

sub transplant {
    my ($self, $brain) = @_;
    
    if (ref $brain ne 'POE::Component::Hailo') {
        croak 'Argument must be a POE::Component::Hailo instance';
    }

    my $old_brain = $self->{Hailo};
    $poe_kernel->post($self->{Hailo}->session_id(), 'shutdown') if !$self->{keep_alive};
    $self->{Hailo} = $brain;
    $self->{keep_alive} = 1;
    return $old_brain;
}

sub S_isupport {
    my ($self, $irc) = splice @_, 0, 2;
    $irc->yield(join => $self->{Own_channel}) if $self->{Own_channel};
    return PCI_EAT_NONE;
}

sub S_ctcp_action {
    my ($self, $irc) = splice @_, 0, 2;
    my $user         = ${ $_[0] };
    my $nick         = (split /!/, $user)[0];
    my $chan         = ${ $_[1] }->[0];
    my $what         = ${ $_[2] };

    return PCI_EAT_NONE if $chan !~ /^[#&!]/;
    
    $poe_kernel->post(
        $self->{session_id},
        '_msg_handler',
        'action',
        $user, 
        $chan,
        "$nick $what",
    ); 
    
    return PCI_EAT_NONE;
}

sub S_public {
    my ($self, $irc) = splice @_, 0, 2;
    my $user         = ${ $_[0] };
    my $chan         = ${ $_[1] }->[0];
    my $what         = ${ $_[2] };

    $poe_kernel->post($self->{session_id} => _msg_handler => 'public', $user, $chan, $what);
    return PCI_EAT_NONE;
}

1;
__END__

=head1 NAME

POE::Component::IRC::Plugin::Hailo - A PoCo-IRC plugin which provides
access to a L<Hailo|Hailo> conversation simulator.

=head1 SYNOPSIS

 #!/usr/bin/env perl
 
 use strict;
 use warnings;
 use POE;
 use POE::Component::IRC::Plugin::AutoJoin;
 use POE::Component::IRC::Plugin::Connector;
 use POE::Component::IRC::Plugin::Hailo;
 use POE::Component::IRC::State;
 
 my $irc = POE::Component::IRC::State->spawn(
     nick   => 'Brainy',
     server => 'irc.freenode.net',
 );
 
 my @channels = ('#public_chan', '#bot_chan');
 
 $irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(Channels => \@channels));
 $irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new());
 $irc->plugin_add('Hailo', POE::Component::IRC::Plugin::Hailo->new(
     Own_channel    => '#bot_chan',
     Ignore_regexes => [ qr{^\s*\w+://\S+\s*$} ], # ignore URL-only lines
     Hailo_args => {
         brain_resource => 'brain.sqlite',
     },
 ));
 
 $irc->yield('connect');
 $poe_kernel->run();

=head1 DESCRIPTION

POE::Component::IRC::Plugin::Hailo is a
L<POE::Component::IRC|POE::Component::IRC> plugin. It provides "intelligence"
through the use of L<POE::Component::Hailo|POE::Component::Hailo>.
It will talk back when addressed by channel members (and possibly in other
situations, see L<C<new>|/"new">). An example:

 --> hailo_bot joins #channel
 <Someone> oh hi there
 <Other> hello there
 <Someone> hailo_bot: hi
 <hailo_bot> oh hi there

All NOTICEs are ignored, so if your other bots only issue NOTICEs like
they should, they will be ignored automatically.

Before using, you should read the documentation for L<Hailo|Hailo>, so you
have an idea of what to pass as the B<'Hailo_args'> parameter to
L<C<new>|/new>.

This plugin requires the IRC component to be
L<POE::Component::IRC::State|POE::Component::IRC::State> or a subclass thereof.

=head1 METHODS

=head2 C<new>

Takes the following optional arguments:

B<'Hailo'>, a reference to an existing
L<POE::Component::Hailo|POE::Component::Hailo> object you have
lying around. Useful if you want to use it with multiple IRC components.
If this argument is not provided, the plugin will construct its own object.

B<'Hailo_args'>, a hash reference containing arguments to pass to the
constructor of a new L<Hailo|Hailo> object.

B<'Own_channel'>, a channel where it will reply to all messages. The plugin
will take care of joining the channel. It will part from it when the plugin
is removed from the pipeline. Defaults to none.

B<'Abuse_interval'>, default is 60 (seconds), which means that user X in
channel Y has to wait that long before addressing the bot in the same channel
if he wants to get a reply. Setting this to 0 effectively turns off abuse
protection.

B<'Talkative'>, when set to a true value, the bot will respond whenever
someone mentions its name (in a PRIVMSG or CTCP ACTION (/me)). If false, it
will only respond when addressed directly with a PRIVMSG. Default is false.

B<'Ignore_masks'>, an array reference of IRC masks (e.g. "purl!*@*") to
ignore.

B<'Ignore_regexes'>, an array reference of regex objects. If a message
matches any of them, it will be ignored. Handy for ignoring messages with
URLs in them.

B<'Method'>, how you want messages to be delivered. Valid options are
'notice' (the default) and 'privmsg'.

Returns a plugin object suitable for feeding to
L<POE::Component::IRC|POE::Component::IRC>'s C<plugin_add> method.

=head2 C<brain>

Takes no arguments. Returns the underlying
L<POE::Component::Hailo|POE::Component::Hailo> object being used
by the plugin.

=head2 C<transplant>

Replaces the brain with the supplied
L<POE::Component::Hailo|POE::Component::Hailo> instance. Shuts
down the old brain if it was instantiated by the plugin itself.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

This distribution is based on
L<POE::Component::IRC::Plugin::MegaHAL|POE::Component::IRC::Plugin::MegaHAL>
by the same author.

=cut
