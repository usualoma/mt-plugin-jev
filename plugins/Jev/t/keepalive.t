use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Select;
use JSON::PP;
use POSIX ();
use MT::Plugin::Jev::Client;

# Exercise real LWP HTTP/1.1 connections on loopback. The tiny server keeps
# multiple sockets open so forked workers can reuse their own connection.
my $dir = tempdir(CLEANUP => 1);
my $log = "$dir/requests.jsonl";
my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
    Listen => 8, ReuseAddr => 1) or die $!;
my $url = 'http://127.0.0.1:' . $listener->sockport . '/evaluate';
my $owner = $$;
my $server;
END {
    if ($$ == $owner && $server) {
        kill 'TERM', $server;
        waitpid($server, 0);
    }
}
$server = fork;
die $! unless defined $server;
unless ($server) {
    $SIG{TERM} = sub { POSIX::_exit(0) };
    $SIG{ALRM} = sub { POSIX::_exit(1) };
    alarm 20;
    my $select = IO::Select->new($listener);
    my (%buffers, %connection_ids, $connection);
    while (1) {
        for my $socket ($select->can_read(1)) {
            if ($socket == $listener) {
                my $client = $listener->accept or POSIX::_exit(1);
                $client->autoflush(1);
                $select->add($client);
                $buffers{fileno($client)} = '';
                $connection_ids{fileno($client)} = ++$connection;
                next;
            }
            my $fd = fileno($socket);
            my $length = sysread($socket, my $chunk, 65536);
            unless ($length) {
                $select->remove($socket);
                close $socket;
                delete $buffers{$fd};
                next;
            }
            $buffers{$fd} .= $chunk;
            next unless $buffers{$fd} =~ /\A(.*?)\r\n\r\n/s;
            my $headers = $1;
            my ($size) = $headers =~ /^Content-Length:\s*(\d+)/mi;
            my ($pid) = $headers =~ /^X-Test-Pid:\s*(\d+)/mi;
            POSIX::_exit(1) unless defined $size && defined $pid;
            my $header_size = length($headers) + 4;
            next if length($buffers{$fd}) < $header_size + $size;
            substr($buffers{$fd}, 0, $header_size, '');
            my $body = substr($buffers{$fd}, 0, $size, '');
            my $data = JSON::PP->new->utf8->decode($body);
            my @ids = sort keys %{$data->{state}{documents}};
            open my $fh, '>>', $log or POSIX::_exit(1);
            print {$fh} JSON::PP->new->encode({connection => $connection_ids{$fd},
                pid => 0 + $pid, ids => \@ids}), "\n";
            close $fh;
            my $reply = JSON::PP->new->encode({answers => {map {
                ($_ . '_match' => {type => 'noul', noul => 0.9}, $_ . '_score' => {type => 'score', score => 3})
            } @ids}});
            print {$socket} "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                . length($reply) . "\r\nConnection: keep-alive\r\n\r\n" . $reply;
        }
    }
}
close $listener;

{
    package Local::LoopbackUA;
    use parent 'LWP::UserAgent';
    sub request {
        my ($self, $request) = @_;
        $request = $request->clone;
        $request->uri($self->{test_url});
        $request->header('X-Test-Pid' => $$);
        return $self->SUPER::request($request);
    }
}

my $client = MT::Plugin::Jev::Client->new(api_key => 'fake', model => 'jev-latest');
bless $client->{ua}, 'Local::LoopbackUA';
$client->{ua}{test_url} = $url;
$client->{ua}->protocols_allowed(['http']);
$client->{ua}->proxy(http => undef);
sub batch { [map { +{id => "entry_$_", fields => [{name => 'text', value => 'Example'}]} } $_[0] .. $_[0] + 4] }

$client->evaluate_batch(condition => 'query', candidates => batch(101)) for 1..2;
my $answers = $client->evaluate_batches(condition => 'query', batches => [map { batch($_ * 5 + 1) } 0..9]);
is scalar keys %$answers, 50, 'all parallel answers received';
$client->evaluate_batch(condition => 'query', candidates => batch(201));
$client->{ua}->conn_cache->drop;

open my $fh, '<', $log or die $!;
my @requests = map { JSON::PP->new->decode($_) } <$fh>;
is scalar @requests, 13, 'no request lost, duplicated or retried';
my @parent = grep { $_->{pid} == $$ } @requests;
is $parent[0]{connection}, $parent[1]{connection}, 'sequential calls reuse the same connection';
isnt $parent[0]{connection}, $parent[2]{connection}, 'parent connection cleared before forking';
my %workers;
push @{$workers{$_->{pid}}}, $_ for grep { $_->{pid} != $$ } @requests;
is scalar keys %workers, 5, 'five HTTP workers by default';
my %worker_connections;
for my $pid (sort keys %workers) {
    is scalar @{$workers{$pid}}, 2, 'two requests per worker';
    my %connections = map { $_->{connection} => 1 } @{$workers{$pid}};
    is scalar keys %connections, 1, 'worker reuses its connection across all batches';
    $worker_connections{$_}++ for keys %connections;
    ok !exists $connections{$parent[0]{connection}}, 'worker never inherits parent TLS/HTTP connection';
}
is scalar keys %worker_connections, 5, 'workers have distinct connections';
done_testing;
