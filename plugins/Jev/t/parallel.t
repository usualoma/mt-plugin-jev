use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use HTTP::Response;
use Time::HiRes qw(time sleep);
use POSIX ();
use MT::Plugin::Jev::Client;

{
    package Local::ParallelUA;
    use Fcntl qw(:flock);
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub timeout { $_[0]{timeout} = $_[1] }
    sub record {
        my ($self, %data) = @_;
        open my $fh, '>>', $self->{log} or die $!;
        flock $fh, LOCK_EX or die $!;
        print {$fh} JSON::PP->new->utf8->encode({%data, pid => $$, at => Time::HiRes::time()}) . "\n";
        close $fh or die $!;
    }
    sub request {
        my ($self, $request) = @_;
        my $data = JSON::PP->new->utf8->decode($request->content);
        my @ids = sort keys %{$data->{state}{documents}};
        my $id = $ids[0];
        my $attempt = ++$self->{attempts}{$id};
        $self->record(phase => 'start', ids => \@ids, body => $request->content, timeout => $self->{timeout});
        my $mode = $self->{mode} || '';
        Time::HiRes::sleep($mode eq 'deadline' ? 5 : $mode eq 'fail' && $id ne 'entry_001' ? 2 : 0.08);
        $self->record(phase => 'end', ids => \@ids);
        return HTTP::Response->new(429, 'Limit', ['Retry-After' => 1])
            if $mode eq 'retry' && $id eq 'entry_001' && $attempt == 1;
        return HTTP::Response->new(500, 'Failure', [], 'sensitive content')
            if $mode eq 'fail' && $id eq 'entry_001';
        my %answers;
        for my $id (@ids) {
            my ($n) = $id =~ /(\d+)$/;
            $answers{$id . '_match'} = {type => 'noul', noul => $n / 100};
            $answers{$id . '_score'} = {type => 'score', score => $n % 5};
        }
        return HTTP::Response->new(200, 'OK', [], JSON::PP->new->encode({answers => \%answers, usage => {input_tokens => 123}}));
    }
}

my $dir = tempdir(CLEANUP => 1);
my @batches = map {
    my $batch = $_;
    [map { +{id => sprintf('entry_%03d', $_), fields => [{name => 'text', label => '本文', value => "日本語の文書 $_"}]} }
        ($batch * 5 + 1) .. ($batch * 5 + 5)]
} 0 .. 9;
my $sequence = 0;
sub client {
    my ($mode, %args) = @_;
    my $log = "$dir/" . ++$sequence;
    my $ua = Local::ParallelUA->new(log => $log, mode => $mode);
    return (MT::Plugin::Jev::Client->new(ua => $ua, api_key => 'fake', model => 'jev-latest', %args), $log);
}
sub events {
    my ($log) = @_;
    open my $fh, '<', $log or return [];
    return [map { JSON::PP->new->utf8->decode($_) } <$fh>];
}
sub caught { my ($cb) = @_; local $@; eval { $cb->() }; $@ }
sub assert_reaped {
    my ($events) = @_;
    my %pids = map { $_->{pid} => 1 } @$events;
    for my $pid (keys %pids) {
        is waitpid($pid, POSIX::WNOHANG()), -1, "worker $pid has already been reaped";
        ok !kill(0, $pid), "worker $pid is no longer running";
    }
}

subtest 'configurable concurrency preserves answers, payloads and usage' => sub {
    my ($serial, $serial_log) = client();
    my %serial_answers;
    my $start = time;
    for my $batch (@batches) {
        my $result = $serial->evaluate_batch(condition => '料金への言及がない', candidates => $batch);
        @serial_answers{keys %$result} = values %$result;
    }
    my $serial_time = time - $start;
    for my $concurrency (undef, 1, 2, 4, 5, 10) {
        my $expected = $concurrency // 5;
        subtest defined $concurrency ? "$concurrency concurrent requests" : 'default five concurrent requests' => sub {
            my ($parallel, $parallel_log) = client(undef, concurrency => $concurrency);
            $start = time;
            my $result = $parallel->evaluate_batches(condition => '料金への言及がない', batches => \@batches);
            my $parallel_time = time - $start;
            is_deeply $result, \%serial_answers, 'scores and document identity unchanged';
            is $parallel->input_tokens, $serial->input_tokens, 'usage summed across workers';
            my $events = events($parallel_log);
            my @starts = grep { $_->{phase} eq 'start' } @$events;
            is scalar @starts, 10, 'same ten requests for fifty documents';
            is_deeply [sort map { $_->{body} } @starts],
                [sort map { $_->{body} } grep { $_->{phase} eq 'start' } @{events($serial_log)}],
                'every outgoing payload is byte-for-byte identical to sequential evaluation';
            my ($active, $maximum) = (0, 0);
            for my $event (@$events) {
                $active += $event->{phase} eq 'start' ? 1 : -1;
                $maximum = $active if $active > $maximum;
            }
            is $maximum, $expected, 'configured number of requests overlap';
            is $active, 0, 'all requests finished';
            if ($expected == 1) {
                is_deeply [map { $_->{pid} } @starts], [($$) x 10], 'sequential mode never forks';
            } else {
                assert_reaped($events);
            }
            diag sprintf '50 documents, simulated 80ms HTTP latency: sequential %.3fs; concurrency %d: %.3fs',
                $serial_time, $expected, $parallel_time;
        };
    }
};

subtest 'retry waits in one worker while the other continues, with out-of-order results' => sub {
    my ($client, $log) = client('retry', concurrency => 2);
    my $result = $client->evaluate_batches(condition => 'query', batches => [@batches[0..3]]);
    is scalar keys %$result, 20, 'all answers retained after retry';
    is $result->{entry_001}{noul}, 0.01, 'delayed answer mapped by ID';
    my @starts = grep { $_->{phase} eq 'start' } @{events($log)};
    is scalar @starts, 5, 'four requests plus exactly one retry';
    my @retry = grep { $_->{ids}[0] eq 'entry_001' } @starts;
    cmp_ok $retry[1]{at} - $retry[0]{at}, '>=', 1, 'Retry-After respected';
    my ($other) = grep { $_->{ids}[0] eq 'entry_016' } @starts;
    cmp_ok $other->{at}, '<', $retry[1]{at}, 'other worker advances during backoff';
    assert_reaped(events($log));
};

subtest 'failure and deadline terminate other workers without returning partial results' => sub {
    for my $mode ('fail', 'deadline') {
        my ($client, $log) = client($mode);
        my $start = time;
        my $error = caught(sub { $client->evaluate_batches(condition => 'query', batches => \@batches,
            deadline => time + ($mode eq 'deadline' ? 0.2 : 3)) });
        isa_ok $error, 'MT::Plugin::Jev::Error';
        like "$error", $mode eq 'fail' ? qr/HTTP/ : qr/timed out/, "$mode propagates to caller";
        unlike "$error", qr/sensitive/, 'content never included in error';
        cmp_ok time - $start, '<', 1.5, 'does not wait for the slow worker';
        my $events = events($log);
        is scalar(grep { $_->{phase} eq 'start' } @$events), 5, 'five workers start but later batches are not sent';
        assert_reaped($events);
        my $before = scalar @$events;
        sleep 0.1;
        is scalar @{events($log)}, $before, 'nothing continues after return';
    }
    my ($client) = client();
    is scalar keys %{$client->evaluate_batches(condition => 'query', batches => [@batches[0..1]])}, 10,
        'a subsequent search succeeds';
};

subtest 'empty and single batches do not fork' => sub {
    my ($client, $log) = client();
    is_deeply $client->evaluate_batches(condition => 'query', batches => []), {}, 'empty input';
    ok !-e $log, 'empty input sends no request';
    $client->evaluate_batches(condition => 'query', batches => [$batches[0]]);
    is events($log)->[0]{pid}, $$, 'single batch uses existing sequential path';
};

subtest 'worker count is capped to nonempty batches' => sub {
    my ($client, $log) = client(undef, concurrency => 10);
    my $original = \&MT::Plugin::Jev::Client::_worker;
    no warnings qw(redefine once);
    local *MT::Plugin::Jev::Client::_worker = sub {
        my ($self, @args) = @_;
        $self->{ua}->record(phase => 'worker');
        $original->($self, @args);
    };
    my $answers = $client->evaluate_batches(condition => 'query', batches => [[], @batches[0..2], []]);
    is scalar keys %$answers, 15, 'all three batches evaluated';
    my $events = events($log);
    is scalar(grep { $_->{phase} eq 'worker' } @$events), 3, 'only three workers created';
    is scalar(grep { $_->{phase} eq 'start' } @$events), 3, 'no duplicate requests';
    assert_reaped($events);
};

subtest 'sequential batches share the search deadline' => sub {
    my ($client, $log) = client(undef, concurrency => 1);
    my $error = caught(sub { $client->evaluate_batches(condition => 'query', batches => \@batches,
        deadline => time + 0.12) });
    isa_ok $error, 'MT::Plugin::Jev::Error';
    like "$error", qr/timed out/, 'does not reset deadline for each batch';
    my @starts = grep { $_->{phase} eq 'start' } @{events($log)};
    cmp_ok scalar @starts, '<', 10, 'remaining batches are not sent';
    is_deeply [map { $_->{pid} } @starts], [($$) x @starts], 'sequential timeout does not leave workers';
};

done_testing;
