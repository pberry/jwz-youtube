#!/usr/bin/perl -w
# Copyright © 2013-2017 Jamie Zawinski <jwz@jwz.org>
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
# The .feeds file can also contain the URLs of Youtube users.
#
# Created: 29-Jul-2013.

require 5;
use diagnostics;
use strict;

use Fcntl;
use Fcntl ':flock'; # import LOCK_* constants
use LWP::Simple;
use Date::Parse;
use HTML::Entities;
use IPC::Open2;

use open ":encoding(utf8)";

my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.54 $' =~ m/\s(\d[.\d]+)\s/s);

my $verbose = 0;
my $debug_p = 0;

my $youtubedown = 'youtubedown';
my $youtube_api = 'youtube-api.pl';
my $youtube_api_user = $ENV{USER};

$youtube_api_user = 'yesthatjwz' if ($youtube_api_user eq 'jwz'); # blargh


my $max_urls = 100;	# Don't download more than N from a feed at once.
my $max_days = 16;	# Ignore any RSS entry more than N days old.
my $max_hist = 30000;	# Remember only this many total downloaded URLs.


# Convert any HTML entities to Unicode characters.
#
sub html_unquote($) {
  my ($s) = @_;
  return HTML::Entities::decode_entities ($s);
}


# Duplicated in youtubedown.
#
sub canonical_url($;) {
  my ($url) = @_;

  # Forgive pinheaddery.
  $url =~ s@&amp;@&@gs;
  $url =~ s@&amp;@&@gs;

  # Add missing "https:"
  $url = "https://$url" unless ($url =~ m@^https?://@si);

  # Rewrite youtu.be URL shortener.
  $url =~ s@^https?://([a-z]+\.)?youtu\.be/@https://youtube.com/v/@si;

  # Rewrite Vimeo URLs so that we get a page with the proper video title:
  # "/...#NNNNN" => "/NNNNN"
  $url =~ s@^(https?://([a-z]+\.)?vimeo\.com/)[^\d].*\#(\d+)$@$1$3@s;

  $url =~ s@^http:@https:@s;	# Always https.

  my ($id, $site, $playlist_p);

  # Youtube /view_play_list?p= or /p/ URLs.
  if ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                (?: view_play_list\?p= |
                    p/ |
                    embed/p/ |
                    .*? [?&] list=(?:PL)? |
                    embed/videoseries\?list=(?:PL)?
                )
                ([^<>?&,]+) ($|&) @sx) {
    ($site, $id) = ($1, $2);
    $url = "https://www.$site.com/view_play_list?p=$id";
    $playlist_p = 1;

  # Youtube "/verify_age" URLs.
  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/+
	     .* next_url=([^&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* continue = ( http%3A [^?&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* next = ( [^?&]+)@sx
          ) {
    $site = $1;
    $url = url_unquote($2);
    if ($url =~ m@&next=([^&]+)@s) {
      $url = url_unquote($1);
      $url =~ s@&.*$@@s;
    }
    $url = "https://www.$site.com$url" if ($url =~ m@^/@s);

  # Youtube /watch/?v= or /watch#!v= or /v/ URLs.
  } elsif ($url =~ m@^https?:// (?:[a-z]+\.)?
                     (youtube) (?:-nocookie)? (?:\.googleapis)? \.com/+
                     (?: (?: watch/? )? (?: \? | \#! ) v= |
                         v/ |
                         embed/ |
                         .*? &v= |
                         [^/\#?&]+ \#p(?: /[a-zA-Z\d] )* /
                     )
                     ([^<>?&,\'\"]+) ($|[?&]) @sx) {
    ($site, $id) = ($1, $2);
    $url = "https://www.$site.com/watch?v=$id";

  # Youtube "/user" and "/profile" URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                     (?:user|profile).*\#.*/([^&/]+)@sx) {
    $site = $1;
    $id = url_unquote($2);
    $url = "https://www.$site.com/watch?v=$id";
    error ("unparsable user next_url: $url") unless $id;

  # Vimeo /NNNNNN URLs
  # and player.vimeo.com/video/NNNNNN
  # and vimeo.com/m/NNNNNN
  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/(?:video/|m/)?(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Vimeo /videos/NNNNNN URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*/videos/(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Vimeo /channels/name/NNNNNN URLs.
  # Vimeo /ondemand/name/NNNNNN URLs.
  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/[^/]+/[^/]+/(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Vimeo /album/NNNNNN/video/MMMMMM
  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/album/\d+/video/(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Vimeo /moogaloop.swf?clip_id=NNNNN
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*clip_id=(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Tumblr /video/UUU/NNNNN
  } elsif ($url =~
           m@^https?://[-_a-z\d]+\.(tumblr)\.com/video/([^/]+)/(\d{8,})/@si) {
    my $user;
    ($site, $user, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "https://$user.$site.com/post/$id";

  # Tumblr /post/NNNNN
  } elsif ($url =~ m@^https?://([-_a-z\d]+)\.(tumblr)\.com
                     /.*?/(\d{8,})(/|$)@six) {
    my $user;
    ($user, $site, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "https://$user.$site.com/post/$id";

  # Vine /v/NNNNN
  } elsif ($url =~ m@^https?://([-_a-z\d]+\.)?(vine)\.co/v/([^/?&]+)@si) {
    (undef, $site, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "https://$site.co/v/$id";

  # Instagram /p/NNNNN
  } elsif ($url =~ m@^https?://([-_a-z\d]+\.)?(instagram)\.com/p/([^/?&]+)@si) {
    (undef, $site, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "https://www.$site.com/p/$id";

  # Twitter /USER/status/NNNNN
  } elsif ($url =~ m@^https?://([-_a-z\d]+\.)?(twitter)\.com/([^/?&]+)
                     /status/([^/?&]+)@six) {
    my $user;
    (undef, $site, $user, $id) = ($1, $2, $3, $4);
    $site = lc($site);
    $url = "https://$site.com/$user/status/$id";

  } else {
    return ();
    error ("unparsable URL: $url");
  }

  return ($url, $id, $site);
}


# Returns the list of video URLs in the given feed.
# ($title, $total_urls, @urls)
#
sub scan_feed($$) {
  my ($url, $kill_re) = @_;

  # Rewrite Youtube and Vimeo channel URLs to the RSS version.
  #
  if ($url =~ m@youtube\.com/(user|channel)/([^/?&]+)(:?/([^/?&]+))?@si) {
    #
    # This used to work, but the v2 API was turned off in Apr 2015,
    # so now we have to do it the hard way.
    #
    #   $url = ('http://gdata.youtube.com/feeds/base/users/' . $1 .
    #          '/uploads?v=2&alt=rss');
    #
    my ($kind, $uid, $list) = ($1, $2);

    # Oh hey, this undocumented thing works on uploads -- but for how long?
    if (($list || 'uploads') eq 'uploads') {
      $url = ('https://www.youtube.com/feeds/videos.xml?' .
              ($kind eq 'user' ? 'user' : 'channel_id') . '=' . $uid);
    } else {
      return scan_youtube_user_feed ($uid, $url);
    }
  } elsif ($url =~ m@vimeo.com/(album/([^/?&]+))@si) {
    $url = 'http://vimeo.com/' . $1 . '/rss';
  } elsif ($url =~ m@vimeo.com/(((channels|groups)/)?([^/?&]+))@si) {
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

  if ($body eq '') {
    print STDERR "$progname: $url empty\n" if ($verbose);
    return ('', 0);
  }

  utf8::decode ($body);  # Pack multi-byte UTF-8 back into wide chars.

  error ("looks like HTML: $url") if ($body =~ m/^<(HEAD|!DOCTYPE)\b/si);

  $body =~ s/(<(entry|item)\b)/\001$1/gsi;
  my @items = split("\001", $body);

  my $head = shift @items || '';

  my ($ftitle) = ($head =~ m@<title\b[^<>]*>([^<>]*)@s);
  $ftitle = html_unquote ($ftitle) if $ftitle;
  $ftitle = $url unless $ftitle;


  my @all_urls = ();
  my %dups;
  my $total = 0;
  foreach (@items) {
    my ($title) = m@<title\b[^<>]*>([^<>]*)@s;
    my ($author) = m@<dc:creator\b[^<>]*>([^<>]*)@s;
    my ($link) = m@<link\b[^<>]*>\s*([^<>]*)@s;
       ($link) = m@<link\b[^<>]*href=[\"\']?([^<>\"\"]+)@si unless $link;
       ($link) = m@<media:content\b[^<>]*url=[\"\']?([^<>\"\"]+)@si
         unless $link;
    my ($guid) = m@<guid\b[^<>]*>([^<>]*)@s;
    my ($date) = m@<pubDate\b[^<>]*>([^<>]*)@s;
       ($date) = m@<published\b[^<>]*>([^<>]*)@s unless ($date);
    my ($html) = m@<content\b[^<>]*>\s*(.*?)</content@s;
       ($html) = m@<summary\b[^<>]*>\s*(.*?)</summary@s unless ($html);
       ($html) = m@<description\b[^<>]*>\s*(.*?)</description@s unless ($html);
       ($html) = m@<media:description\b[^<>]*>\s*(.*?)</media@s unless ($html);
    $html = '' unless $html;

    foreach ($title, $author, $html) {
      $_ = '' unless $_;
      $_ =~ s@<!\[CDATA\[\s*(.*)\s*\]\]>@$1@gs;
    }

    $html = "$link\n$html" if $link;
    $html = "$guid\n$html" if $guid;

    $title  = html_unquote($title); # RSS to HTML
    $author = html_unquote($author);
    $html   = html_unquote($html);

    $title  = html_unquote($title); # HTML to Unicrud
    $author = html_unquote($author);
    # Don't convert $html, we still need to parse it.

    foreach ($title, $author) {
      s/ \\[ux] { ([a-z0-9]+)   } / chr(hex($1)) /gsexi;  # \u{XXXXXX}
      s/ \\[ux]   ([a-z0-9]{4})   / chr(hex($1)) /gsexi;  # \uXXXX

      s/\xA0/ /gs;  # &nbsp;
    }


    # Convert HTML to plain text for killfile.
    my $text = $html;
    $text =~ s@<[^<>]*>@@gs;
    $text = html_unquote ($text);
    $text =~ s/[^\000-\176]/ /gs;    # unicrud

    my $text2 = $text;
    $text2 =~ s/\\/\\\\/gs;
    $text2 =~ s/\n/\\n/gs;


    # promonews.tv doesn't include the videos in their RSS feed!
    # Pull it from the web site instead.
    #
    if ($url =~ m/promonews|antville/s) {
      print STDERR "$progname: reading $link\n" if ($verbose > 1);

      $count = 0;
      while (1) {
        $html = LWP::Simple::get ($link);
        if ($html) {
          $html =~ s/[\r\n]/ /gsi;
          utf8::decode ($html);  # Pack multi-byte UTF-8 back into wide chars.
          last;
        }
        last if (++$count > $retries);
        print STDERR "$progname: $link failed, retrying...\n"
          if ($verbose > 2);
        sleep (1 + $count);
      }
    }

    $date = str2time ($date || '') || time();
    my $age = (time() - $date) / (60 * 60 * 24);
    my $old_p = ($age > $max_days);
    my $kill_p = ($kill_re &&
                  (($title  && $title  =~ m/$kill_re/so) ||
                   ($author && $author =~ m/$kill_re/so) ||
                   ($text   && $text   =~ m/$kill_re/mo)));

    if ($verbose > 1) {
      $guid = '<undef>' unless defined ($guid);
      if ($kill_p) {
        print STDERR "$progname:   killfile $guid \"$author\" \"$title\" \"$text2\"\n";
      } elsif ($old_p) {
        print STDERR "$progname:   skipping $guid \"$author\" \"$title\"" .
                     " (" . int($age) . " days old)\n";
      } else {
        print STDERR "$progname:   checking $guid \"$author\" \"$title\" \"$text2\"\n";
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
      $u =~ s@\#.*$@@s;
      ($u, undef, undef) = canonical_url ($u);
      next unless $u;

      next if ($u =~ m/videoseries/s);
      next if ($u =~ m/view_play_list/s);

      # Youtube video with a bogus ID
      next if ($u =~ m/watch\?v=([^?&]*)/s && length($1) < 11);

      next if ($dups{$u});
      $dups{$u} = 1;
      $total++;

      if ($old_p || $kill_p) {
        if ($verbose > 1) {
          if ($kill_p) {
            print STDERR "$progname:     killfile \"$u\"\n";
          } else {
            print STDERR "$progname:     skipping \"$u\"" .
                         " (" . int($age) . " days old)\n";
          }
        }
        next;
      }

      push @all_urls, [ $u, $author, $title, $_ ];
      print STDERR "$progname:     found $u\n" if ($verbose > 1);
    }
  }

  if ($total == 0) {  # && $verbose > 2
    $_ = join("\n", @items);
    $_ =~ s/</\n</gs;
    $_ =~ s@\n</@</@gs;
    print STDERR "$progname: WARNING: no URLs in $url:\n\n$_\n\n";
  }

  print STDERR "\n" if ($verbose > 1);

  if (@all_urls > $max_urls) {
    my $n = @all_urls - $max_urls;
    print STDERR "$progname: discarding $n URLs from $url (" .
      $all_urls[$max_urls][1] . ")\n"
      if ($verbose);
    @all_urls = @all_urls[0 .. $max_urls-1];
  }

  return ($ftitle, $total, @all_urls);
}


sub scan_youtube_user_feed($$) {
  my ($uid, $url) = @_;
  my @cmd = ($youtube_api, $youtube_api_user, '--list', $url);
  my ($in, $out);
  print STDERR "$progname: exec: " . join(' ', @cmd) . "\n" if ($verbose);
  my $pid = open2 ($out, $in, @cmd);
  close ($in);
  my @lines = <$out>;
  waitpid ($pid, 0);

  error ("$youtube_api: no output") unless @lines;

  my $pl_url = shift @lines;
  my @all_urls = ();

  foreach my $line (@lines) {
    my ($id, $vtitle) = ($line =~ m/^(.*?)\t(.*?)\n?$/s);
    my $vurl = 'http://www.youtube.com/watch?v=' . $id;
    ($vurl, undef, undef) = canonical_url ($vurl);
    push @all_urls, [ $vurl, $vtitle ];
    print STDERR "$progname:     found $vurl\n" if ($verbose > 1);
  }

  my $total = @all_urls;

  if ($total == 0 && $verbose > 2) {
    print STDERR "$progname: WARNING: no URLs on $url\n";
  }

  if (@all_urls > $max_urls) {
    my $n = @all_urls - $max_urls;
    print STDERR "$progname: discarding $n URLs from $url (" .
      $all_urls[$max_urls][1] . ")\n"
      if ($verbose);
    @all_urls = @all_urls[0 .. $max_urls-1];
  }

  return ($uid, $total, @all_urls);
}


# Download the URL into the current directory.
# Returns 1 if successful, 0 otherwise.
#
sub download_url($$$$) {
  my ($url, $title, $ftitle, $bwlimit) = @_;

  foreach ($title, $ftitle) {
    s/^youtube[^a-z\d]*//si;  # Thanks I am aware.
  }

  utf8::encode ($title);  # Unpack wide chars to multi-byte UTF-8
  $ftitle .= ':' if $ftitle;

  my @cmd = ($youtubedown, "--suffix");
  push @cmd, "--quiet" if ($verbose == 0);
  push @cmd, ("--bwlimit", $bwlimit) if ($bwlimit);
  push @cmd, "-" . ("v" x ($verbose - 3)) if ($verbose > 3);
  push @cmd, "--size" if ($debug_p);
  push @cmd, ("--prefix", $ftitle) if $ftitle;
# push @cmd, ("--title", $title) if $title;
  push @cmd, $url;

  print STDERR "$progname: exec: " . join(" ", @cmd) . "\n"
    if ($verbose > 1 || $debug_p);

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


sub pull_feeds($$) {
  my ($dir, $bwlimit) = @_;

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
  open ($hist_fd, ($debug_p ? '<' : '+>>'), $hist) ||
    error ("writing $hist: $!");
  if (! flock ($hist_fd, LOCK_EX | LOCK_NB)) {
    my $age = time() - (stat($hist_fd))[9];
    # If we haven't been locked that long, exit silently.
    exit (1) if ($verbose == 0 && $age < 60 * 60 * 2);
    $age = sprintf("%d:%02d:%02d", $age/60/60, ($age/60)%60, $age%60);
    if ($debug_p) {
      print STDERR "already locked for $age: $hist\n";
    } else {
      error ("already locked for $age: $hist");
    }
  }

  seek ($hist_fd, 0, 0) || error ("rewinding $hist: $!");
  print STDERR "$progname: locked $hist\n"
    if ($verbose > 1);

  utime (undef, undef, $hist_fd);   # acquired lock, set file mtime to now

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
      next if (m/^\s*$/s);
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
    foreach my $P (@urls) {
      my ($url, $uauthor, $utitle) = @$P;
      next if ($debug_p < 2 && $hist{$url});
      $hist{$url} = 1;
      push @new_urls, $P;
    }
    print STDERR "$progname: found " . scalar(@new_urls) . " new of " .
                 "$ftotal URLs in \"$ftitle\"\n"
      if ($verbose);

    # Try to find a sane prefix for the downloaded file, to show where it
    # came from.
    #
    my $ftitle2;
    if ($feed =~ m@(?:channels|groups|user|vimeo\.com)/([^/]+)/?$@si) {
      $ftitle2 = $1;
    } elsif ($ftitle =~ m/^Uploads by (.*)$/si) {
      $ftitle2 = $1;
    } elsif ($ftitle =~ m@^Videos matching: (.*)$@si) {
      $ftitle2 = $1;
    } elsif ($ftitle =~ m@^Vimeo / (.*)$@si) {
      $ftitle2 = $1;
    } elsif ($feed =~ m@^https?://[^.]+\.([^./]+)\.@si && 
             $1 !~ m/jwz|tumblr|feedburner|blogspot/si) {
      $ftitle2 = $1;
    } else {
      $ftitle2 = $ftitle;
    }
    $ftitle2 =~ s@'s videos$@@si;
    $ftitle2 =~ s@^.* \| @@si;
    $ftitle2 = undef if ($ftitle2 =~ m/^http/si);

    foreach my $P (reverse (@new_urls)) {
      my ($url, $uauthor, $utitle, $rss_entry) = @$P;
      my $ftitle3 = $ftitle2;

      $uauthor = '' if ($ftitle3 =~ m/^(promonews|antville|reddit)/si);

      $ftitle3 = "$uauthor: $ftitle3" if $uauthor;

      #### Kludge for titles of the dnalounge "calendar videos" feed.
      $ftitle3 = "$ftitle2: $uauthor: $1"
        if ($utitle && $utitle =~ m/^DNA Lounge: ([a-z]{3} \d\d?) /si);

      next unless download_url ($url, $utitle, $ftitle3, $bwlimit);
      next if $debug_p;

print STDERR "## DL $url\n$feed\n$rss_entry\n\n"
  if ($feed =~ m/youtube-dnalounge/si);

      unshift @hist, $url;  # put it on the front
      @hist = @hist[0 .. $max_hist-1] if (@hist > $max_hist);

      # Write the history file after each URL download, in case we die.
      # We are still holding a lock on this file.
      #
      if (! $debug_p) {
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
  }

  # History file has already been updated.  Now we can release the lock.
  #
  flock ($hist_fd, LOCK_UN) || error ("unlocking $hist: $!");
  close ($hist_fd);
  print STDERR "$progname: unlocked $hist\n"
    if ($verbose > 1);

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
  my $bwlimit;
  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/) { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^--?debug$/) { $debug_p++; }
    elsif (m/^--?bwlimit$/) { $bwlimit = shift @ARGV; }
    elsif (m/^-./) { usage; }
    elsif (!$dir) { $dir = $_; }
    else { usage; }
  }

  usage unless ($dir);
  pull_feeds ($dir, $bwlimit);
}

main();
exit 0;
