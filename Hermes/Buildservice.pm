#
# Copyright (c) 2008 Klaas Freitag <freitag@suse.de>, Novell Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################
# Contributors:
#  Klaas Freitag <freitag@suse.de>
#  Andreas Bauer <abauer@suse.de>
#
package Hermes::Buildservice;

use strict;
use Exporter;
use Carp;

use HTML::Template;
use LWP::UserAgent;
use URI::Escape;

use Hermes::Config;
use Hermes::DB;
use Hermes::Log;
use Hermes::Person;
use Hermes::Util;

use constant MAINTAINER_FLAG => 1;
use constant BUGOWNER_FLAG   => 2;

use Data::Dumper;

use vars qw(@ISA @EXPORT @EXPORT_OK );

@ISA	    = qw(Exporter);
@EXPORT	    = qw( expandNotification );
@EXPORT_OK  = qw( extractUserFromMeta usersOfPackage usersOfProject applyFilter);

our($hermesUserInfoRef, $cachedProject, $cachedPackage, $cachedStrictPackage, $cachedWatchlist);

#
# generates a list of subscriptions which want to receive the incoming 
# notification type based on the parameters. The subscriptions are identified
# by their database ids. The subscriptions have all the information like receiver,
# delivery and delay which is needed.
#
sub expandNotification( $$ )
{
  my( $msgType, $paramRef ) = @_;

  # query the receivers
  my $sql = "SELECT subs.id, subs.person_id, p.stringid FROM ";
  $sql .= "subscriptions subs, msg_types mt, persons p WHERE ";
  $sql .= "subs.msg_type_id = mt.id AND mt.msgtype=? AND subs.person_id=p.id AND enabled=1";

  my $query = dbh()->prepare( $sql );
  $query->execute( $msgType );
  my @subsIds;
  #no need to invalidate as long as we do not run for days invalidateCache();

  while( my ($subscriptId, $personId, $personString) = $query->fetchrow_array()) {
    $paramRef->{_userId} = $personString;
    # and the personId is user in the project.
    my @filters = getFilters( $subscriptId );
    # loop over all filters. Since these filter are implicit AND connected, all
    # filters have to apply.
    my $filterOk = 1;
    foreach my $filterRef ( @filters ) {
      $filterOk = applyFilter( $paramRef, $filterRef );
      if( ! $filterOk ) {
	log( 'info', "Filter $filterRef->{filterlog} failed!" );
	last;
      }
      log( 'info', $filterRef->{filterlog} . " adds user to to-line: $personString ($personId)." );
    }
    if( $filterOk ) {
      log('info', "Subscription $subscriptId wants this notification!" );
      push @subsIds, $subscriptId;
    }
  }
  return \@subsIds;
}


sub getFilters( $ ) 
{
  my( $subscriptId ) = @_;

  my $sql = "SELECT p.name, filter.operator, filter.filterstring FROM ";
  $sql   .= "subscription_filters filter, parameters p WHERE "; 
  $sql   .= "filter.parameter_id=p.id AND filter.subscription_id=?";

  my $query = dbh()->prepare( $sql );
  $query->execute( $subscriptId );

  my @re;
  while( my ($param, $operator, $string) = $query->fetchrow_array()) {
    push @re, { param => $param, operator => $operator, string => $string,
	        filterlog => "Filter: param <$param>, operator <$operator>, value <$string>" };
  }
  return @re;
}

sub applyFilter( $$ ) 
{
  my( $paramHash, $filterRef ) = @_;
  my $res = 1;

  if( $filterRef->{operator} eq "special" ) {

    if( $filterRef->{string} eq "_myprojects" ) {
      # user must be involved in the project.
      my $user = $paramHash->{_userId};
      my $prj = $paramHash->{project};
      return 0 unless $prj;

      log( 'info', "Checking user <$user> involved in prj <$prj>" );
      my $userHashRef = usersOfProject( $prj );
      $res = 0 unless( userHasFunction( $userHashRef, $user, MAINTAINER_FLAG ) );
    } elsif( $filterRef->{string} eq "_mypackages" ) {
      # user must be involved in the package.
      my $user = $paramHash->{_userId};
      my $pkg = $paramHash->{package};
      my $prj = $paramHash->{project};
      return 0 unless $prj;
      return 0 unless $pkg;

      log( 'info', "Checking user <$user> involved in pkg <$prj::$pkg>" );
      my $userHashRef = usersOfPackage( $prj, $pkg );
      $res = 0 unless( userHasFunction( $userHashRef, $user, MAINTAINER_FLAG ) );
    } elsif( $filterRef->{string} eq "_packagebugowner" ) {
      # user must be involved in the package.
      my $user = $paramHash->{_userId};
      my $pkg = $paramHash->{package};
      my $prj = $paramHash->{project};
      return 0 unless $prj;
      return 0 unless $pkg;

      log( 'info', "Checking user <$user> is bugowner of <$prj::$pkg>" );
      my $userHashRef = usersOfPackage( $prj, $pkg );
      $res = 0 unless( userHasFunction( $userHashRef, $user, BUGOWNER_FLAG ) );
    } elsif( $filterRef->{string} eq "_mypackagesstrict" ) {
      # user must be involved in the package.
      my $user = $paramHash->{_userId};
      my $pkg = $paramHash->{package};
      my $prj = $paramHash->{project};
      my $pkgStr = $pkg || 'unknown';

      log( 'info', "Checking strict for user <$user> involved in pkg <$pkgStr>" );
      my $userHashRef = strictUsersOfPackage( $prj, $pkg );
      $res = 0 unless( userHasFunction( $userHashRef, $user, MAINTAINER_FLAG ) );
    } elsif( $filterRef->{string} eq "_mywatchlist" ) {
      #user mast have $project in his watchlist
      my $user = $paramHash->{_userId};
      my $prj = $paramHash->{project};

      log( 'info', "Checking for project <$prj> in watchlist of user <$user>" );
      my $watchlistHash = userWatchList( $user );

      if ( ! $watchlistHash->{$prj} ) {
        log( 'info', "User <$user> has project <$prj> NOT in his watchlist" );
        $res = 0;
      } else {
        log( 'info', "User <$user> has project <$prj> in his watchlist" );
      }

    } elsif( $filterRef->{string} eq "_myrequests" ) {
      # user is maintainer of target project
      my $user = $paramHash->{_userId};
      my $tPrj = $paramHash->{targetproject};
      my $tPack = $paramHash->{targetpackage};
      if( $tPrj ) {
        log( 'info', "Checking if <$user> is interested in request <$paramHash->{id}> ".
                     "with target project <$tPrj>");
	# userOfPackage returns both the project- and pack users.
	my $tPackUsers = usersOfPackage( $tPrj, $tPack );
	$res = 0 unless( userHasFunction( $tPackUsers, $user, MAINTAINER_FLAG ) );
      } else {
	log('info', "targetproject <$tPrj> does not exist!" );
	$res = 0;
      }
    } else {
      log( 'error', "Unknown special filter type " . $filterRef->{string} );
      $res = 0;
    }
  } elsif( $filterRef->{operator} eq "oneof" ) {
    # the parameter value must be contained in the filter string
    if( $paramHash->{ $filterRef->{param} } ) {
      # the parameter named in the filter exists
      my $searchStr = $paramHash->{ $filterRef->{param} };
      $searchStr =~ s/^\s*//; # wipe whitespaces
      $searchStr =~ s/\s*$//;
      $searchStr = quotemeta( $searchStr );

      my $str = $filterRef->{string};

      my @possibleValues = split( /\s*,\s*/, $str );
      my $success = grep( /\b$searchStr\b/, @possibleValues );
      log( 'info', "Filtering oneof <$searchStr> in [" . join( "|", @possibleValues ) . "]: " . $success );

      if( $success ) {
	$res = 1;
      } else {
	$res = 0;
      }
    } else {
      log( 'warning', "Filter references on non existing param <$filterRef->{param}>" );
      $res = 0;
    }
  } elsif( $filterRef->{operator} eq "containsitem" ) {
    # the parameter contains a comma separated list and this filter returns true if the 
    # filter string is in the list.
    $res = 0;
    if( $paramHash->{ $filterRef->{param} } ) {
      my $listStr = $paramHash->{ $filterRef->{param} };
      my @list = split( /\s*[|,]\s*/, $listStr );
      my $sstr = quotemeta( $filterRef->{string} );
      # log('debug', "containsItem search-String: $sstr" );
      my $cnt = grep ( /\b$sstr\b/, @list );
      # log('debug', "containsitem-Filter: Search in list: " . join( ' - ', @list ) . " #hits=$cnt" );
      if( $cnt > 0 ) {
	$res = 1;
      }
      log( 'debug', "containsitem-Filter: $filterRef->{string} is part of $listStr?: $res" );
    }
  } elsif( $filterRef->{operator} eq "regexp" ) {
    # the parameter value must match the regexp in the filter
    if( $paramHash->{ $filterRef->{param} } ) {
      my $searchStr = $paramHash->{ $filterRef->{param} };
      $searchStr =~ s/^\s*//; # wipe whitespaces
      $searchStr =~ s/\s*$//;
      $searchStr = quotemeta( $searchStr );

      my $regexp = $filterRef->{string};

      log( 'info', "Filtering regexp <$regexp> on <$searchStr>?" );

      unless( $searchStr && $regexp && $searchStr =~ /$regexp/ ) {
	$res = 0;
      }
    } else {
      $res = 0;
    }
  } else {
    log( 'error', "Invalid operator string: <$filterRef->{operator}" );
    $res = 0;
  }

  return $res;
}

sub userHasFunction( $$$ )
{
  my ($userHashRef, $user, $flag ) = @_;
  my $res = 0;
  
  if( $userHashRef->{$user} ) {
    if( ($userHashRef->{$user} & $flag) == $flag ) {
      log( 'info', "User <$user> exists <$flag> in the required function: $userHashRef->{$user}" );
      $res = 1;
    } else {
      log( 'info', "User exists, but NOT in the required function" );
    }
  } else {
    log( 'info', "User not existing in user hash." );
  }
  return $res;
}

sub usersOfProject( $ )
{
  my ($project) = @_;
  confess 'no Project defined!' unless $project;

  if( defined $cachedProject->{$project} ) {
    log( 'info', "Using userdata for $project from cache" );
    return $cachedProject->{$project}; 
  }

  my $userHashRef;

  if( $project ) {
    my $meta = callOBSAPI( 'prjMetaRef', ($project) );
    $userHashRef = extractUserFromMeta( $meta );
    $cachedProject->{$project} = $userHashRef;
    foreach my $user ( keys %{$userHashRef} ) {
      log('info', "This user is in project <$project>: $user, function $userHashRef->{$user}" );
    }
  } else {
    # unfortunately no project param, but privacy is requested.
    # -> problem
    log( 'warning', "Problem: Privacy is requested, but no param project" );
  }

  return $userHashRef;
}

sub usersOfPackage( $;$ )
{
  my ($project, $package) = @_;
  confess 'no Project defined!' unless $project;
  confess 'no Package defined!' unless $package;
  if( defined $cachedPackage->{"$project/$package"} ) {
    log( 'info', "Using userdata for package $project/$package from cache" );
    return $cachedPackage->{"$project/$package"}; 
  }

  # All users of the project
  my $userHashRef = usersOfProject( $project );
  
  if( $package ) {
    # since the api changed its behaviour silently to not longer 
    # deliver the users inherited from the project with the package
    # here both prj and pack need to be queried.
    my $packUserHashRef = strictUsersOfPackage($project,$package);
  
    # Unite the content of both hashes
    foreach my $k ( keys %$packUserHashRef ) {
      if( ! $userHashRef->{$k} ) {
        $userHashRef->{$k} = $packUserHashRef->{$k};
      }
    }
  }

  $cachedPackage->{"$project/$package"} = $userHashRef;
  log( 'info', "These users are in package <$project/$package>: " . join( ', ', keys %{$userHashRef} ) );

  return $userHashRef;
}

# Return the users which are really listed in the package meta
# data. No consideration of inherited users from the project.
#
# No caching here because the cache contains inherited as well
# (yet, patches welcome)
sub strictUsersOfPackage( $$ )
{
 my ($project, $package) = @_;
  
  my $userHashRef;

  if( $project && $package ) {
    
    if( defined $cachedStrictPackage->{"$project/$package"} ) {
        log( 'info', "Using strict userdata for package $project/$package from cache" );
        return $cachedStrictPackage->{"$project/$package"};
     }

    # since the api changed its behaviour silently to not longer 
    # deliver the users inherited from the project with the package
    # here both prj and pack need to be queried.
    my $meta = callOBSAPI( 'pkgMetaRef', ( $project,$package ) );
    $userHashRef = extractUserFromMeta( $meta );
    $cachedStrictPackage->{"$project/$package"} = $userHashRef;
  } else {
    log( 'info', "Problem: No sufficient input for strict package users" );
  }
  return $userHashRef;
}

sub userWatchList( $$ )
{
  my ($user) = @_;
  if( defined $cachedWatchlist->{$user} ) {
    log( 'info', "Using userdata for $user from cache" );
    return $cachedWatchlist->{$user};
  }
  my $watchlistHashRef;

  if( $user ) {
    my $meta = callOBSAPI( 'personMetaRef', ($user) );
    $watchlistHashRef = extractProjectsFromPersonMeta( $meta );
    $cachedWatchlist->{$user} = $watchlistHashRef;
    log( 'info', "These Projects are watched by <$user>: " . join( ', ', keys %{$watchlistHashRef} ) );
  } else {
    # unfortunately no user param, but privacy is requested.
    # -> problem
    log( 'warning', "Problem: Privacy is requested, but no param user" );
  }

  return $watchlistHashRef;
}

sub invalidateCache()
{
    $cachedPackage = {};
    $cachedProject = {};
    $cachedWatchlist = {};
}

#
# calls the OBS API, uses credentials aus conf/hermes.conf
# returns the result as plain text or undef, if an error happened
# FIXME: report errors back to calling functions
#
sub callOBSAPI( $$;$ )
{
  my ( $function, @urlparams ) = @_;
  my $urlstr = "";
# my $auth = 0;


# new perl way: join( '/', map{ uri_escape($_)} (@urlparams) );
  foreach (@urlparams){
    if ( $urlstr ne "" ){
      $urlstr .= '/';
    }
    $urlstr .= uri_escape( $_ );
  }


# return {} unless( $project );

  my %results;
  my $OBSAPIUrl = $Hermes::Config::OBSAPIBase ||  "http://api.opensuse.org/";
  $OBSAPIUrl =~ s/\s*$//; # Wipe whitespace at end.
  $OBSAPIUrl .= '/' unless( $OBSAPIUrl =~ /\/$/ );

  my $ua = LWP::UserAgent->new;
  $ua->agent( "Hermes Buildservice Processor" );
  my $uri = $OBSAPIUrl . "public/";

  if( $function eq 'prjMetaRef' || $function eq 'pkgMetaRef') {
    $uri .= "source/$urlstr/_meta";
  } elsif($function eq 'personMetaRef') {
    $uri .= "person/$urlstr/_watchlist";
#   $auth = 1;
  }

  log( 'info', "Asking $uri with GET" );

  my $req = HTTP::Request->new( GET => $uri );
  $req->header( 'Accept' => 'text/xml' );
# $req->authorization_basic( $Hermes::Config::OBSAPIUser,
#     			      $Hermes::Config::OBSAPIPasswd ) if($auth);

  my $res = $ua->request( $req );

  if( $res->is_success ) {
    return $res->decoded_content;
  } else {
    log( 'error', "API Call Error: " . $res->status_line . "\n" );
    return undef;
  }
}

#
# returns a list of users from the projects meta file
#
sub extractUserFromMeta( $ )
{
  my ($meta) = @_;
  my %retuser;
 
  if( $meta ) {
    my @xml = split(/\n/, $meta );
    my @people = grep ( /<person .+?\/>/, @xml );
    foreach my $pl (@people) {
      if( $pl =~ /role=\"(maintainer|bugowner)/i ) {
	my $role = $1;
	if( $pl =~ /userid=\"(.+?)\"/ ) {
	  my $flag = 0;
	  $flag = MAINTAINER_FLAG if( $role eq "maintainer" );
	  $flag = BUGOWNER_FLAG if( $role eq "bugowner" );
	  my $oldFlag = $retuser{$1} || 0;
	  $retuser{$1} = $oldFlag + $flag;
	}
      }
    }
  }
  return \%retuser;
}

#
# returns a list of watched projects of a user
#
sub extractProjectsFromPersonMeta( $ )
{
  my ($meta) = @_;
  my %retwatchlist;

  if ( $meta ) {
    $meta =~ s/.*?<watchlist>\s*(.*?)\s*<\/watchlist>.*/$1/gs;

    foreach ( split(/\n/,$meta) ) {
      $_ =~ s/.*?<project\sname\=\"(.+?)\"\/>.*?/$1/;
      $retwatchlist{$_} = 1 if( $1 );
    }
  }
  return \%retwatchlist;
}

$hermesUserInfoRef = personInfo( 'hermes2' ); # Get the hermes user info
if( $hermesUserInfoRef->{id} ) {
  log( 'info', "The hermes user id is " . $hermesUserInfoRef->{id} );
}

1;
