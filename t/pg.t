#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More;
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny qw(:all);
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Plan;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::pg';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';
}

is_deeply [$CLASS->config_vars], [
    client        => 'any',
    username      => 'any',
    password      => 'any',
    db_name       => 'any',
    host          => 'any',
    port          => 'int',
    sqitch_schema => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new;
isa_ok my $pg = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'psql' . ($^O eq 'Win32' ? '.exe' : '');
is $pg->client, $client, 'client should default to psql';
is $pg->sqitch_schema, 'sqitch', 'sqitch_schema default should be "sqitch"';
for my $attr (qw(username password db_name host port)) {
    is $pg->$attr, undef, "$attr default should be undef";
}

is $pg->destination, $ENV{PGDATABASE} || $ENV{PGUSER} || $ENV{USER},
    'Destination should fall back on environment variables';

my @std_opts = (
    '--quiet',
    '--no-psqlrc',
    '--no-align',
    '--tuples-only',
    '--set' => 'ON_ERROR_ROLLBACK=1',
    '--set' => 'ON_ERROR_STOP=1',
    '--set' => 'sqitch_schema=sqitch',
);
is_deeply [$pg->psql], [$client, @std_opts],
    'psql command should be std opts-only';

##############################################################################
# Test other configs for the destination.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{PGDATABASE};
    local $ENV{PGUSER};
    local $ENV{USER};
    for my $env (qw(PGDATABASE PGUSER USER)) {
        my $pg = $CLASS->new(sqitch => $sqitch);
        local $ENV{$env} = "\$ENV=whatever";
        is $pg->destination, "\$ENV=whatever", "Destination should read \$$env";
    }

    $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $pg->destination, 'hi', 'Destination should read username';

    $ENV{PGDATABASE} = 'mydb';
    $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $pg->destination, 'mydb', 'Destination should prefer $PGDATABASE to username';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.pg.client'        => '/path/to/psql',
    'core.pg.username'      => 'freddy',
    'core.pg.password'      => 's3cr3t',
    'core.pg.db_name'       => 'widgets',
    'core.pg.host'          => 'db.example.com',
    'core.pg.port'          => 1234,
    'core.pg.sqitch_schema' => 'meta',
);
$std_opts[-1] = 'sqitch_schema=meta';
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $pg = $CLASS->new(sqitch => $sqitch), 'Create another pg';

is $pg->client, '/path/to/psql', 'client should be as configured';
is $pg->username, 'freddy', 'username should be as configured';
is $pg->password, 's3cr3t', 'password should be as configured';
is $pg->db_name, 'widgets', 'db_name should be as configured';
is $pg->destination, 'widgets', 'destination should default to db_name';
is $pg->host, 'db.example.com', 'host should be as configured';
is $pg->port, 1234, 'port should be as configured';
is $pg->sqitch_schema, 'meta', 'sqitch_schema should be as configured';
is_deeply [$pg->psql], [qw(
    /path/to/psql
    --username freddy
    --dbname   widgets
    --host     db.example.com
    --port     1234
), @std_opts], 'psql command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    'client'        => '/some/other/psql',
    'username'      => 'anna',
    'db_name'       => 'widgets_dev',
    'host'          => 'foo.com',
    'port'          => 98760,
);

ok $pg = $CLASS->new(sqitch => $sqitch), 'Create a pg with sqitch with options';

is $pg->client, '/some/other/psql', 'client should be as optioned';
is $pg->username, 'anna', 'username should be as optioned';
is $pg->password, 's3cr3t', 'password should still be as configured';
is $pg->db_name, 'widgets_dev', 'db_name should be as optioned';
is $pg->destination, 'widgets_dev', 'destination should still default to db_name';
is $pg->host, 'foo.com', 'host should be as optioned';
is $pg->port, 98760, 'port should be as optioned';
is $pg->sqitch_schema, 'meta', 'sqitch_schema should still be as configured';
is_deeply [$pg->psql], [qw(
    /some/other/psql
    --username anna
    --dbname   widgets_dev
    --host     foo.com
    --port     98760
), @std_opts], 'psql command should be as optioned';

##############################################################################
# Test _run() and _spool().
can_ok $pg, qw(_run _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

$exp_pass = 's3cr3t';
ok $pg->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $pg->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $pg->psql],
    'Command should be passed to spool()';

# Remove the password.
delete $config{'core.pg.password'};
ok $pg = $CLASS->new(sqitch => $sqitch), 'Create a pg with sqitch with no pw';
$exp_pass = undef;
ok $pg->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $pg->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $pg->psql],
    'Command should be passed to spool() again';

##############################################################################
# Test file and handle running.
ok $pg->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$pg->psql, '--file', 'foo/bar.sql'],
    'File should be passed to run()';

ok $pg->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $pg->psql],
    'Handle should be passed to spool()';
$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Can we do live tests?
can_ok $CLASS, qw(
    initialized
    initialize
    run_file
    run_handle
    log_deploy_step
    log_fail_step
    log_deploy_step
    log_apply_tag
    log_remove_tag
    is_deployed_tag
    is_deployed_step
    check_requires
    check_conflicts
);

my @cleanup;
END {
    $pg->_dbh->do(
        "SET client_min_messages=warning; $_"
    ) for @cleanup;
}

subtest 'live database' => sub {
    $sqitch = App::Sqitch->new(
        username  => 'postgres',
        sql_dir   => Path::Class::dir(qw(t pg)),
        plan_file => Path::Class::file(qw(t pg sqitch.plan)),
    );
    $pg = $CLASS->new(sqitch => $sqitch);
    try {
        $pg->_dbh;
    } catch {
        plan skip_all => "Unable to connect to a database for testing: $_";
    };

    plan 'no_plan';

    ok !$pg->initialized, 'Database should not yet be initialized';
    push @cleanup, 'DROP SCHEMA ' . $pg->sqitch_schema . ' CASCADE';
    ok $pg->initialize, 'Initialize the database';
    ok $pg->initialized, 'Database should now be initialized';
    is $pg->_dbh->selectcol_arrayref('SHOW search_path')->[0], 'sqitch',
        'The search path should be set';

    # Try it with a different schema name.
    ok $pg = $CLASS->new(
        sqitch => $sqitch,
        sqitch_schema => '__sqitchtest',
    ), 'Create a pg with postgres user and __sqitchtest schema';

    is $pg->latest_item, undef, 'No init, no events';
    is $pg->latest_tag,  undef, 'No init, no tags';
    is $pg->latest_step, undef, 'No init, no steps';

    ok !$pg->initialized, 'Database should no longer seem initialized';
    push @cleanup, 'DROP SCHEMA __sqitchtest CASCADE';
    ok $pg->initialize, 'Initialize the database again';
    ok $pg->initialized, 'Database should be initialized again';
    is $pg->_dbh->selectcol_arrayref('SHOW search_path')->[0], '__sqitchtest',
        'The search path should be set to the new path';

    is $pg->latest_item, undef, 'Still no events';
    is $pg->latest_tag,  undef, 'Still no tags';
    is $pg->latest_step, undef, 'Still no steps';

    # Make sure a second attempt to initialize dies.
    throws_ok { $pg->initialize } 'App::Sqitch::X',
        'Should die on existing schema';
    is $@->ident, 'pg', 'Mode should be "pg"';
    is $@->message, __x(
        'Sqitch schema "{schema}" already exists',
        schema => '__sqitchtest',
    ), 'And it should show the proper schema in the error message';

    throws_ok { $pg->_dbh->do('INSERT blah INTO __bar_____') } 'App::Sqitch::X',
        'Database error should be converted to Sqitch exception';
    is $@->ident, $DBI::state, 'Ident should be SQL error state';
    like $@->message, qr/^ERROR:  /, 'The message should be the PostgreSQL error';
    like $@->previous_exception, qr/\QDBD::Pg::db do failed: /,
        'The DBI error should be in preview_exception';

    ##########################################################################
    # Test log_deploy_step().
    my $plan = $sqitch->plan;
    my $step = $plan->node_at(0);
    is $step->name, 'users', 'Should have "users" step';
    ok !$pg->is_deployed_step($step), 'The step should not be deployed';
    ok $pg->log_deploy_step($step), 'Deploy "users" step';
    ok $pg->is_deployed_step($step), 'The step should now be deployed';

    is $pg->latest_item, 'users', 'Should get "users" for latest item';
    is $pg->latest_step, 'users', 'Should get "users" for latest step';
    is $pg->latest_tag,   undef,  'Should get undef for latest tag';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step_id, step, requires, conflicts, deployed_by FROM steps'
    ), [[$step->id, 'users', [], [], $pg->actor]],
        'A record should have been inserted into the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, node_id, node, logged_by FROM events'
    ), [['deploy', $step->id, 'users', $pg->actor]],
        'A record should have been inserted into the events table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [], 'No records should have been inserted into the tags table';

    ##########################################################################
    # Test log_revert_step().
    ok $pg->log_revert_step($step), 'Revert "users" step';
    ok !$pg->is_deployed_step($step), 'The step should no longer be deployed';

    is $pg->latest_item, undef, 'Should get undef for latest item';
    is $pg->latest_step, undef, 'Should get undef for latest step';
    is $pg->latest_tag,  undef, 'Should get undef for latest tag';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step_id, step, requires, conflicts, deployed_by FROM steps'
    ), [], 'The record should have been deleted from the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, node_id, node, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id, 'users', $pg->actor],
        ['revert', $step->id, 'users', $pg->actor],
    ], 'The revert event should have been logged';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [], 'Should still have no tag records';

    ##########################################################################
    # Test log_fail_step().
    ok $pg->log_fail_step($step), 'Fail "users" step';
    ok !$pg->is_deployed_step($step), 'The step still should not be deployed';

    is $pg->latest_item, undef, 'Should still get undef for latest item';
    is $pg->latest_step, undef, 'Should still get undef for latest step';
    is $pg->latest_tag,  undef, 'Should still get undef for latest tag';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step_id, step, requires, conflicts, deployed_by FROM steps'
    ), [], 'Still should have not steps table record';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, node_id, node, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id, 'users', $pg->actor],
        ['revert', $step->id, 'users', $pg->actor],
        ['fail',   $step->id, 'users', $pg->actor],
    ], 'The fail event should have been logged';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [], 'Should still have no tag records';

    ##########################################################################
    # Test log_apply_tag().
    my $tag = $plan->node_at(1), 'Get a tag';
    is $tag->format_name, '@alpha', 'It should be the @alpha tag';
    ok !$pg->is_deployed_tag($tag), 'The tag should not yet be deployed';

    throws_ok { $pg->log_apply_tag($tag) } 'App::Sqitch::X',
        'Should get error attempting to apply tag';
    is $@->ident, '23503', 'Should have a FK violation ident';
    like $@->message, qr/\btags_step_id_fkey\b/,
        'Error should mention the FK constraint';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [], 'Should still have no tag records';
    ok !$pg->is_deployed_tag($tag), 'The tag still should not be deployed';

    # So we need the step.
    ok $pg->log_deploy_step($step), 'Deploy "users" step';
    is $pg->latest_item, 'users', 'Should again get "users" for latest item';
    is $pg->latest_step, 'users', 'Should again get "users" for latest step';
    is $pg->latest_tag,   undef,  'Should still get undef for latest tag';

    # Now deploy the tag.
    ok $pg->log_apply_tag($tag), 'Deploy a tag';
    ok $pg->is_deployed_tag($tag), 'The tag should now be deployed';
    is $pg->latest_item, '@alpha', 'Should now get "@alpha" for latest item';
    is $pg->latest_step, 'users',  'Should still get "users" for latest step';
    is $pg->latest_tag,  '@alpha', 'Should now get "@alpha" for latest tag';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step_id, step, requires, conflicts, deployed_by FROM steps'
    ), [[$step->id, 'users', [], [], $pg->actor]],
        'A new record should have been inserted into the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [
        [$tag->id, '@alpha', $step->id, $pg->actor],
    ], 'The tag should have been logged';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, node_id, node, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id, 'users',  $pg->actor],
        ['revert', $step->id, 'users',  $pg->actor],
        ['fail',   $step->id, 'users',  $pg->actor],
        ['deploy', $step->id, 'users',  $pg->actor],
        ['apply',  $tag->id,  '@alpha', $pg->actor],
    ], 'The apply event should have been logged';

    ##########################################################################
    # Test log_remove_tag().
    ok $pg->log_remove_tag($tag), 'Remove tag';

    ok !$pg->is_deployed_tag($tag), 'The tag should no longer be deployed';
    is $pg->latest_item, 'users', 'Should once more "users" for latest item';
    is $pg->latest_step, 'users', 'Should still get "users" for latest step';
    is $pg->latest_tag,   undef,  'Should onde more undef for latest tag';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [], 'The tag should have been removed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, node_id, node, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id, 'users',  $pg->actor],
        ['revert', $step->id, 'users',  $pg->actor],
        ['fail',   $step->id, 'users',  $pg->actor],
        ['deploy', $step->id, 'users',  $pg->actor],
        ['apply',  $tag->id,  '@alpha', $pg->actor],
        ['remove', $tag->id,  '@alpha', $pg->actor],
    ], 'The remove event should have been logged';

    ##########################################################################
    # Test a step with prereqs.
    ok $pg->log_apply_tag($tag),   'Apply the tag again';
    ok $pg->is_deployed_tag($tag), 'The tag again should be deployed';
    is $pg->latest_item, '@alpha', 'Should again get "@alpha" for latest item';
    is $pg->latest_step, 'users',  'Should still get "users" for latest step';
    is $pg->latest_tag,  '@alpha', 'Should again get "@alpha" for latest tag';

    ok my $step2 = $plan->node_at(2), 'Get the second step';
    ok $pg->log_deploy_step($step2),  'Deploy second step';
    is $pg->latest_item, 'widgets',   'Should get "widgets" for latest item';
    is $pg->latest_step, 'widgets',   'Should  get "widgets" for latest step';
    is $pg->latest_tag,  '@alpha',    'Should still get "@alpha" for latest tag';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step_id, step, requires, conflicts, deployed_by
          FROM steps
         ORDER BY deployed_at
    }), [
        [$step->id,  'users', [], [], $pg->actor],
        [$step2->id, 'widgets', ['users'], ['dr_evil'], $pg->actor],
    ], 'Should have both steps and requires/conflcits deployed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, node_id, node, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id,  'users',   $pg->actor],
        ['revert', $step->id,  'users',   $pg->actor],
        ['fail',   $step->id,  'users',   $pg->actor],
        ['deploy', $step->id,  'users',   $pg->actor],
        ['apply',  $tag->id,   '@alpha',  $pg->actor],
        ['remove', $tag->id,   '@alpha',  $pg->actor],
        ['apply',  $tag->id,   '@alpha',  $pg->actor],
        ['deploy', $step2->id, 'widgets', $pg->actor],
    ], 'The new step deploy should have been logged';

=begin comment

    ##########################################################################
    # Test conflicts and requires.
    is_deeply [$pg->check_conflicts($step)], [], 'Step should have no conflicts';
    is_deeply [$pg->check_requires($step)], [], 'Step should have no missing prereqs';

    my $step3 = App::Sqitch::Plan::Step->new(
        name      => 'whatever',
        tag       => $tag,
        conflicts => ['users', 'widgets'],
        requires  => ['fred', 'barney', 'widgets'],
    );
    is_deeply [$pg->check_conflicts($step3)], [qw(users widgets)],
        'Should get back list of installed conflicting steps';
    is_deeply [$pg->check_requires($step3)], [qw(fred barney)],
        'Should get back list of missing prereq steps';

    # Revert gamma.
    ok $pg->begin_revert_tag($tag2), 'Begin reverting "gamma" step';
    ok $pg->revert_step($step2), 'Revert "gamma"';
    ok $pg->commit_revert_tag($tag2), 'Commit "gamma" reversion';
    ok !$pg->is_deployed_step($step2), 'The "widgets" step should no longer be deployed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, applied_by FROM tags ORDER BY applied_at'
    ), [
        [5, $pg->actor],
    ], 'Should have only the one step record now';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5]],
        'Only the alpha tags should be in tag_names';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), [
        ['users', 5, $pg->actor, [], []],
    ], 'Only the "users" step should be in the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at OFFSET 12'
    ), [
        ['revert', 'users', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'widgets', ['gamma'], $pg->actor],
        ['apply', '', ['gamma'], $pg->actor],
        ['revert', 'widgets', ['gamma'], $pg->actor],
        ['remove', '', ['gamma'], $pg->actor],
    ], 'The revert and removal should have been logged';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT NOT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname = 'widgets'
        );
    })->[0], 'The "widgets" revert script should have been run again';

    is_deeply [$pg->check_conflicts($step3)], [qw(users)],
        'Should now see only "users" as a conflict';
    is_deeply [$pg->check_requires($step3)], [qw(fred barney widgets)],
        'Should get back list all three missing prereq steps';

    ##########################################################################
    # Test failures.
    ok $pg->begin_deploy_tag($tag2), 'Begin "gamma" tag again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, applied_by FROM tags ORDER BY applied_at'
    ), [
        [5, $pg->actor],
        [7, $pg->actor],
    ], 'Should have only both tag records again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5], ['gamma', 7]],
        'Both sets of tag names should be present';

    ok $pg->log_fail_step($step2), 'Log the fail step';
    ok $pg->rollback_deploy_tag($tag2), 'Roll back "gamma" tag with "widgets" step';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, applied_by FROM tags ORDER BY applied_at'
    ), [
        [5, $pg->actor],
    ], 'Should have only the first tag record again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5]],
        'Should have only the first tag names again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at OFFSET 18'
    ), [
        ['revert', 'widgets', ['gamma'], $pg->actor],
        ['remove', '', ['gamma'], $pg->actor],
        ['fail', 'widgets', ['gamma'], $pg->actor],
    ], 'The failure should have been logged';

=cut

};

done_testing;
