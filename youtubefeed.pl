#!/usr/bin/perl -w
# Copyright © 2013 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Reads a list of feeds and downloads every video mentioned in them.
# Keeps a list of already-downloaded URLs to avoid repeats.
# Requires "youtubedown".
#
# Usage: youtubefeed.pl ~/Movies/Feeds/
#
#   Feeds/.feeds	List of RSS/Atom URLs, one per line.
#   Feeds/.killfile	Regexps, one per line. Compared against the title
#			of the feed entry, not the title of the video.
#   Feeds/.state	Where the list of already-downloaded URLs is written.
#
# Created: 29-Jul-2013.

require 5;
use diagnostics;
use strict;

use Fcntl;
use Fcntl ':flock'; # import LOCK_* constants
use LWP::Simple;
use Date::Parse;

use open ":encoding(utf8)";

my $progname = $0; $progname =~ s@.*/@@g;
my $version = q{ $Revision: 1.3 $ }; $version =~ s/^[^\d]+([\d.]+).*/$1/;

my $verbose = 0;
my $debug_p = 0;

my $youtubedown = 'youtubedown';

my $max_urls = 25;	# Don't download more than N from a feed at once.
my $max_days = 2;	# Ignore any RSS entry more than N days old.
my $max_hist = 10000;	# Remember only this many total downloaded URLs.


# Returns the list of video URLs in the given feed.
# ($title, $total_urls, @urls)
#
sub scan_feed($$) {
  my ($url, $kill_re) = @_;

  # Rewrite Youtube and Vimeo channel URLs to the RSS version.
  #
  if ($url =~ m@youtube\.com/user/([^/?&]+)@si) {
    $url = ('http://gdata.youtube.com/feeds/base/users/' . $1 .
            '/uploads?v=2&alt=rss');
  } elsif ($url =~ m@vimeo.com/((channels/)?([^/?&]+))@si) {
    $url = 'http://vimeo.com/' . $1 . '/videos/rss';
  }

  print STDERR "$progname: reading $url\n" if ($verbose > 1);

  my $min_length = 1024;
  my $retries = 5;
  my $count = 0;
  my $body = '';

  $LWP::Simple::ua->timeout(20);

  while (1) {
    $body = LWP::Simple::get ($url);
    $body = '' unless ($body && length($body) > $min_length);
    last if ($body);
    last if (++$count > $retries);
    print STDERR "$progname: $url failed, retrying...\n"
      if ($verbose > 2);
    sleep (1 + $count);
  }

  $body =~ s/[\r\n]/ /gsi;
  $body =~ s/(<(entry|item)\b)/\n$1/gsi;
  my @items = split("\n", $body);

  my $head = shift @items || '';

  my ($ftitle) = ($head =~ m@<title\b[^<>]*>([^<>]*)@s);
  $ftitle = $url unless $ftitle;


  my @all_urls = ();
  my %dups;
  my $total = 0;
  foreach (@items) {
    my ($title) = m@<title\b[^<>]*>([^<>]*)@s;
    my ($link) = m@<link\b[^<>]*>([^<>]*)@s;
    my ($guid) = m@<guid\b[^<>]*>([^<>]*)@s;
    my ($date) = m@<pubDate\b[^<>]*>([^<>]*)@s;
    my ($html) = m@<content\b[^<>]*>\s*(.*?)</content@s;
       ($html) = m@<summary\b[^<>]*>\s*(.*?)</summary@s unless ($html);
       ($html) = m@<description\b[^<>]*>\s*(.*?)</description@s unless ($html);
    $html = '' unless $html;

    $title =~ s@<!\[CDATA\[\s*(.*?)\s*\]*>*\s*(</title>\s*)?$@$1@gs;

    $html =~ s@<!\[CDATA\[\s*(.*)\s*\]\]>@$1@gs;

    $html = "$link\n$html" if $link;
    $html = "$guid\n$html" if $guid;

    for (my $i = 0; $i < 3; $i++) {
      foreach ($html, $title) {
        s@&lt;@<@gs;
        s@&gt;@>@gs;
        s@&quot;@"@gs;
        s@&apos;@'@gs;
        s@&amp;@&@gs;
      }
    }

    $date = str2time ($date || '') || time();
    my $age = (time() - $date) / (60 * 60 * 24);
    my $old_p = ($age > $max_days);
    my $kill_p = ($title && $kill_re && $title =~ m/$kill_re/sio);

    if ($verbose > 1) {
      if ($kill_p) {
        print STDERR "$progname:   killfile \"$title\"\n";
      } elsif ($old_p) {
        print STDERR "$progname:   skipping \"$title\"" .
                     " (" . int($age) . " days old)\n";
      } else {
        print STDERR "$progname:   checking \"$title\"\n";
      }
    }

    if (!$html) {
      print STDERR "$progname: $ftitle: no body for \"$title\"\n"
        if ($verbose > 1);
      next;
    }

    $html =~ s@([\"\'])(//)@$1http:$2@gs;  # protocol-less URLs.

    my @urls = ();
    $html =~ s!\b(https?:[^\'\"\s<>]+)!{push @urls, $1; $1;}!gxse;

    foreach my $u (@urls) {

      $u =~ s@youtu\.be/@youtube.com/v/@gsi;
      $u =~ s@&feature=[^&?]+@@gsi;

      # Only grab the URLs that youtubedown recognizes.
      # This regexp is duplicated over there.
      #
      if (! (($u =~ m@^(https?://)?
                      ([a-z]+\.)?
                      ( youtube(-nocookie)?\.com/ |
                      youtu\.be/ |
                      vimeo\.com/ |
                      google\.com/ .* service=youtube |
                      youtube\.googleapis\.com
                     )@six) &&
             ($u =~ m/youtube/si
              ? $u =~ m@ watch\? | /v/ | /embed/ @six
              : $u =~ m@ vimeo\.com/ .* /\d{6,} @six))) {
        print STDERR "$progname:     skipping $u\n" if ($verbose > 2);
        next;
      }
      next if ($dups{$u});
      $dups{$u} = 1;
      $total++;
      next if ($old_p || $kill_p);
      push @all_urls, $u;
      print STDERR "$progname:     found $u\n" if ($verbose > 1);
    }
  }

  if ($total == 0 && $verbose > 2) {
    $_ = join("\n", @items);
    $_ =~ s/</\n</gs;
    $_ =~ s@\n</@</@gs;
    print STDERR "$progname: WARNING: no URLs in $url:\n\n$_\n\n";
  }

  print STDERR "\n" if ($verbose > 1);

  @all_urls = @all_urls[0 .. $max_urls-1] if (@all_urls > $max_urls);

  return ($ftitle, $total, @all_urls);
}


# Download the URL into the current directory.
# Returns 1 if successful, 0 otherwise.
#
sub download_url($) {
  my ($url) = @_;

  my @cmd = ($youtubedown, "--suffix");
  push @cmd, "--quiet" if ($verbose == 0);
  push @cmd, "-" . ("v" x ($verbose - 3)) if ($verbose > 3);
  push @cmd, "--size" if ($debug_p);
  push @cmd, $url;

  system (@cmd);

  my $exit = $? >> 8;
  my $sig  = $? & 127;
  my $core = $? & 128;

  return 1 if ($? == 0);
  error ("$cmd[0]: core dumped!") if ($core);
  error ("$cmd[0]: signal $sig!") if ($sig);
  print STDERR ("$progname: $cmd[0]: exited with $exit!\n") 
    if ($exit && $verbose);
  return 0;
}


sub pull_feeds($) {
  my ($dir) = @_;

  binmode (STDOUT, ':utf8');   # video titles in messages
  binmode (STDERR, ':utf8');

  error ("no such directory; $dir") unless (-d $dir);

  $dir =~ s@/+$@@gs;
  my $feeds = "$dir/.feeds";
  my @feeds;
  open (my $in, '<', $feeds) || error ("$feeds: $!");
  while (<$in>) {
    chomp;
    next if (m/^\s*#/s);
    next unless $_;
    push @feeds, $_;
  }
  close $in;

  error ("no URLs in $feeds") unless @feeds;

  print STDERR "$progname: read " . scalar(@feeds) . " URLs from $feeds\n"
    if ($verbose);

  my $hist = "$dir/.state";

  # Use the history file as a mutex.
  #
  my $hist_fd;
  open ($hist_fd, '+>>', $hist)	|| error ("writing $hist: $!");
  flock ($hist_fd, LOCK_EX)	|| error ("locking $hist: $!");
  seek ($hist_fd, 0, 0)         || error ("rewinding $hist: $!");

  my @hist;
  while (<$hist_fd>) {
    chomp;
    next unless $_;
    push @hist, $_;
  }

  print STDERR "$progname: read " . scalar(@hist) . " URLs from $hist\n"
    if ($verbose);

  my %hist;
  foreach my $url (@hist) { $hist{$url} = 1; }


  my $kill_re = '';
  my $kill = "$dir/.killfile";
  if (open (my $in, '<', $kill)) {
    while (<$in>) {
      chomp;
      next if (m/^\s*#/s);
      $kill_re .= '|' if $kill_re;
      $kill_re .= $_;
    }
    close $in;
    print STDERR "$progname: read $kill\n" if ($verbose);
  }


  chdir ($dir) || error ("cd $dir: $!");

  foreach my $feed (@feeds) {

    my ($ftitle, $ftotal, @urls) = scan_feed ($feed, $kill_re);
    my @new_urls = ();
    foreach my $url (@urls) {
      next if ($hist{$url});
      $hist{$url} = 1;
      push @new_urls, $url;
    }
    print STDERR "$progname: found " . scalar(@new_urls) . " new of " .
                 "$ftotal URLs in \"$ftitle\"\n"
      if ($verbose);

    foreach my $url (@new_urls) {
      next unless download_url ($url);
      next if $debug_p;

      unshift @hist, $url;  # put it on the front
      @hist = @hist[0 .. $max_hist-1] if (@hist > $max_hist);

      # Write the history file after each URL download, in case we die.
      # We are still holding a lock on this file.
      #
      truncate ($hist_fd, 0) || error ("truncating $hist: $!");
      seek ($hist_fd, 0, 0)  || error ("rewinding $hist: $!");
      my $h = join("\n", @hist);
      $h .= "\n" if $h;
      print $hist_fd $h;

      # Need to manually position the write handle to the end!
      seek ($hist_fd, 2, 0)  || error ("seeking $hist: $!");

      print STDERR "$progname: wrote " . scalar(@hist) . " URLs to $hist\n"
        if ($verbose > 1);
    }
  }

  # History file has already been updated.  Now we can release the lock.
  #
  flock ($hist_fd, LOCK_UN) || error ("unlocking $hist: $!");
  close ($hist_fd);

  print STDERR "$progname: wrote " . scalar(@hist) . " URLs to $hist\n"
    if ($verbose == 1);
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] directory\n";
  exit 1;
}

sub main() {
  my $dir;
  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/) { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^--?debug$/) { $debug_p++; }
    elsif (m/^-./) { usage; }
    elsif (!$dir) { $dir = $_; }
    else { usage; }
  }

  usage unless ($dir);
  pull_feeds ($dir);
}

main();
exit 0;
