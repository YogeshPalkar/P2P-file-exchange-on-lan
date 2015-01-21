use threads;
use threads::shared;
use Net::Address::IP::Local;
use Time::HiRes qw(usleep nanosleep);
use IO::Socket::INET;
use IO::Socket;
use IO::Socket::Multicast;
use List::MoreUtils qw(firstidx);
use Switch;
use Digest::MD5::File qw( file_md5_hex );
use File::Basename;
use File::Path;
use POSIX qw/ceil/;

require 'splitfile.pl';
require 'joinfile.pl';

#Initial Configuration.
#$startpeerport is the port number that will be used for sending out data.
#$maxinconnections indicates number of download data connections.
#$maxoutconnections indicates number of upload data connections.
#The thread gets you into the network.
my $searchport        = 39999;
my $localport         = 40000;
my $startpeerport     = 50000;
my $localaddress      = Net::Address::IP::Local->public;
my $group             = '239.192.25.25';                   #For multicast
my $destination       = '239.192.25.25:40000';             #For multicast
my $maxinconnections  = 20;
my $maxoutconnections = 20;
my @notpresentchunkarray : shared    = ();
my @requestedchunkarray : shared     = ();
my @requestedchunktimearray : shared = ();
my @presentchunkarray : shared       = ();
my @peerportnumberarray : shared     = ();
my @donearray : shared               = ();
my $delim                            = "::";
my $splittingfile : shared           = 0;
print "\n	****PEER2PEER****	Author: Yogesh Palkar DESE 10262\n\n";
print "Configuration for network...\n";
print
"Enter the maximum number of incoming connections. More connections, more download.\n";
wait unless my $argsinput = <>;
chomp $argsinput;
$maxinconnections = $argsinput;

print
"Enter the maximum number of outgoing connections. More connections, more upload.\n";
wait unless my $argsinput = <>;
chomp $argsinput;
$maxoutconnections = $argsinput;

{
    lock(@peerportnumberarray);
    @peerportnumberarray =
      ( $startpeerport .. $startpeerport + $maxoutconnections );
}

my $multicastsocket = IO::Socket::Multicast->new(
    Proto     => 'udp',
    LocalPort => $localport,
    ReuseAddr => 1,
);
$multicastsocket->mcast_add($group) || die "COULD NOT SET GROUP: $!\n";
$multicastsocket->mcast_loopback(0);
$multicastsocket->mcast_dest($destination);

my $multicastthread = threads->create( \&monitormulticast )->detach();

sleep(1);

while (1) {
    print
"Enter 1 for searching file.\nEnter 2 for downloading file.\nEnter 3 for uploading file.\nEnter 4 for exit.\n";
    wait unless my $argsinput = <>;
    chomp $argsinput;
    switch ($argsinput) {
    	case 1 { searchfile(); }
        case 3 { uploadfile(); }
        case 2 { downloadfile(); }
        case 4 { cleanandexit(); }
        else   { print "Invalid argument $argsinput entered.\n"; }
    }
}

sub monitormulticast {
    print "\nWelcome to the network.\n\n";
    sleep(1);
    while (1) {
        my $rcvmessage;
        next
          unless $multicastsocket->recv( $rcvmessage, 1024 );
        if ( scalar @peerportnumberarray != 0 ) {
            threads->create( \&multicastpacketreceive, $rcvmessage )->detach();
        }
    }
    threads->exit();
    return (0);
}

sub multicastpacketreceive {
    my $data     = $_[0];
    my $sq       = "\'";
    my $packtype = ( split /::/, $data )[0];
    if ( ( $packtype eq "UPLOAD" ) or ( $packtype eq "IWANT" ) ) {
        my $filenamerecv = ( split /::/, $data )[1];
        my $md5recv      = ( split /::/, $data )[2];
        my $chunksize    = ( split /::/, $data )[3];
        my $newdir = $filenamerecv . $md5recv . $chunksize . ".temp";

        if ( -d $newdir ) {
            if ( $packtype eq "IWANT" ) {
                my $chunknumber = ( split /::/, $data )[4];
                $index = firstidx { $_ eq $chunknumber } @presentchunkarray;
                if ( $index != -1 ) {
                    my $destport = ( split /::/, $data )[5];
                    my $destaddr = ( split /::/, $data )[6];
                    while ( scalar @peerportnumberarray == 0 ) {
                        usleep(500000);
                    }
                    {
                        lock(@peerportnumberarray);
                        $localporttcp = pop(@peerportnumberarray);
                    }

                    my $sendsocket = new IO::Socket::INET(
                        PeerHost  => qq($destaddr),
                        PeerPort  => $destport,
                        LocalPort => $localporttcp,
                        Proto     => 'tcp',
                        Reuse     => 1
                    );
                    die "cannot connect to the server $!\n" unless $sendsocket;
                    my $sendmessage = "ISEND"
                      . $delim
                      . $filenamerecv
                      . $delim
                      . $md5recv
                      . $delim
                      . $chunksize
                      . $delim
                      . $chunknumber;
                    print $sendsocket "$sendmessage\n";
                    $data = <$sendsocket>;
                    chomp($data);
                    if ( $data eq "USEND" ) {
                        $split     = "split";
                        $splitfile = $split . $chunknumber;
                        open( SPLITFILE, "$newdir/$splitfile" );
                        while (<SPLITFILE>) {
                            print $sendsocket $_;
                        }
                        close(SPLITFILE);
                    }
                    shutdown( $sendsocket, 2 );
                    {
                        lock(@peerportnumberarray);
                        push( @peerportnumberarray, $localporttcp );
                    }
                }
            }
        }
        elsif ( ( -e $filenamerecv )
            and ( $md5recv == file_md5_hex($filenamerecv) ) )
        {
#If you have the file mentioned, create a folder that contains the split file. And fill the present chunk array with the chunks.
            {
                lock($splittingfile);
                if ( $splittingfile == 0 ) {
                    $splittingfile = 1;
                    open( FILE, $filenamerecv );
                    $filesize = -s FILE;
                    close FILE;
                    splitfile( $filenamerecv, $md5recv, $chunksize );
                    {
                        lock(@donearray);
                        push( @donearray,
                            $filerecv . $md5recv . $chunksize . ".temp" );
                    }
                    {
                        lock(@presentchunkarray);
                        @presentchunkarray =
                          ( 0 .. ( ceil( $filesize / $chunksize ) - 1 ) );
                    }

                    #$splittingfile = 0;
                    {
                        lock(@donearray);
                        push( @donearray,
                            $filenamerecv . $md5recv . $chunksize . ".temp" );
                    }
                }
            }
        }
        elsif ( $packtype eq "UPLOAD" ) {

#Create three threads, one for requesting chunk, one for time out the request and one for receiving responses on tcp. Before that ensure that the arrays needed are properly filled.
            my $filesize = ( split /::/, $data )[4];
            {
                lock(@notpresentchunkarray);
                @notpresentchunkarray =
                  ( 0 .. ( ceil( $filesize / $chunksize ) - 1 ) );
            }
            threads->create( \&sendrequest, $filenamerecv, $md5recv,
                $chunksize )->detach();
            threads->create( \&receivepackettcp, $filenamerecv, $md5recv,
                $chunksize )->detach();
            threads->create( \&timeoutrequest )->detach();
            threads->create( \&requestjoinfile, $filenamerecv, $md5recv,
                $chunksize, ceil( $filesize / $chunksize ) )->detach();
        }
    }
    elsif ( $packtype eq "SEARCH" ) {
        my $filenamerecv = ( split /::/, $data )[1];
        if( -e $filenamerecv ) {
        	$md5 = file_md5_hex($filenamerecv);
			open( FILE, $filenamerecv );
        	my $filesize = -s FILE;
        	close FILE;
        	my $destport = ( split /::/, $data )[2];
            my $destaddr = ( split /::/, $data )[3];
            while ( scalar @peerportnumberarray == 0 ) {
                usleep(500000);
            }
            {
                lock(@peerportnumberarray);
                $localporttcp = pop(@peerportnumberarray);
            }
            my $sendsocket = new IO::Socket::INET(
                PeerHost  => qq($destaddr),
                PeerPort  => $destport,
                LocalPort => $localporttcp,
                Proto     => 'tcp',
                Reuse     => 1
            );
            die "cannot connect to the server $!\n" unless $sendsocket;
            my $sendmessage = "IHAVE"
                  . $delim
                  . $filenamerecv
                  . $delim
                  . $md5
                  . $delim
                  . $filesize;                        	
            print $sendsocket "$sendmessage\n";
            shutdown( $sendsocket, 2 );
        }
    }

    threads->exit();
    return (0);
}

sub requestjoinfile {
    $filename       = $_[0];
    $md5            = $_[1];
    $chunksize      = $_[2];
    $numberofchunks = $_[3];
    while ( scalar @presentchunkarray != $numberofchunks ) { sleep(10); }
    joinfile( $filename, $md5, $chunksize, $numberofchunks );
    {
        lock(@donearray);
        push( @donearray, $filename . $md5 . $chunksize . ".temp" );
    }
    threads->exit();
    return (0);
}

sub sendrequest {
    my $filename  = $_[0];
    my $md5       = $_[1];
    my $chunksize = $_[2];

    while (1) {
        {
            lock(@notpresentchunkarray);
            lock(@requestedchunkarray);
            lock(@requestedchunktimearray);

            if (    ( ( scalar @notpresentchunkarray ) > 0 )
                and ( ( scalar @requestedchunkarray ) < ($maxinconnections) ) )
            {
                $index = int( rand( scalar @notpresentchunkarray ) );

                $notpresentchunk = $notpresentchunkarray[$index];
                for (
                    $i = $index ;
                    $i < ( scalar @notpresentchunkarray ) - 1 ;
                    $i++
                  )
                {
                    $notpresentchunkarray[$i] = $notpresentchunkarray[ $i + 1 ];
                }
                pop(@notpresentchunkarray);
                push( @requestedchunkarray, $notpresentchunk );

                ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst )
                  = localtime();
                push( @requestedchunktimearray,
                    $hour * 3600 + $min * 60 + $sec );

                my $sendmessage = "IWANT"
                  . $delim
                  . $filename
                  . $delim
                  . $md5
                  . $delim
                  . $chunksize
                  . $delim
                  . $notpresentchunk
                  . $delim
                  . $localport
                  . $delim
                  . $localaddress;
                $multicastsocket->mcast_send($sendmessage);
            }
        }
        usleep(50000);
    }
    threads->exit();
    return (0);
}

sub timeoutrequest {
    while (1) {
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
          localtime();
        {
            lock(@requestedchunkarray);
            lock(@requestedchunktimearray);
            lock(@notpresentchunkarray);
            for ( $i = 0 ; $i < scalar @requestedchunkarray ; $i++ ) {
                if ( $requestedchunktimearray[$i] + 5 <
                    $hour * 3600 + $min * 60 + $sec )
                {
                    my $notpresentchunk = $requestedchunkarray[$i];
                    for (
                        $j = $i ;
                        $j < ( scalar @requestedchunkarray ) - 1 ;
                        $j++
                      )
                    {
                        $requestedchunkarray[$j] =
                          $requestedchunkarray[ $j + 1 ];
                        $requestedchunktimearray[$j] =
                          $requestedchunktimearray[ $j + 1 ];
                    }
                    pop(@requestedchunkarray);
                    pop(@requestedchunktimearray);

                    push( @notpresentchunkarray, $notpresentchunk );
                    $i--;
                }
            }
        }
        usleep(400000);
    }
    threads->exit();
    return (0);
}

sub receivepackettcp {
    my $filename  = $_[0];
    my $md5       = $_[1];
    my $chunksize = $_[2];
    $newdir = $filename . $md5 . $chunksize . ".temp";
    mkdir $newdir, 0777;
    my $receivepacketsocket = IO::Socket::INET->new(
        LocalHost => '0.0.0.0',
        LocalPort => $localport,
        Proto     => 'tcp',
        Reuse     => 1,
        Listen    => 50
    ) or die "Couldn't be a tcp server on port $localport : $@\n";

    while (1) {
        my $client = $receivepacketsocket->accept();
        threads->create( \&acceptpackettcp, $client, $filename, $md5,
            $chunksize )->detach();
    }
    threads->exit();
    return (0);
}

sub receivesearchpackettcp {
    my $receivesearchpacketsocket = IO::Socket::INET->new(
        LocalHost => '0.0.0.0',
        LocalPort => $searchport,
        Proto     => 'tcp',
        Reuse     => 1,
        Listen    => 50
    ) or die "Couldn't be a tcp server on port $searchport : $@\n";

    while (1) {
        my $client = $receivesearchpacketsocket->accept();
        threads->create( \&acceptsearchpackettcp, $client )->detach();
    }
    threads->exit();
    return (0);
}

sub acceptsearchpackettcp {
    my $client         = $_[0];
    $data = <$client>;
    chomp($data);
    my $packtype      = ( split /::/, $data )[0];
    if( $packtype eq "IHAVE" ){
    	my $filename       = ( split /::/, $data )[1];
    	my $md5            = ( split /::/, $data )[2];
    	my $filesize       = ( split /::/, $data )[3];
    	my $client_address = $client->peerhost();
    	print "\n$client_address has $filename.\nSize is $filesize bytes.\nMD5 checksum is $md5.\n";
    }
    shutdown( $client, 2 );
}

sub acceptpackettcp {
    my $client         = $_[0];
    my $filename       = $_[1];
    my $md5            = $_[2];
    my $chunksize      = $_[3];
    my $client_address = $client->peerhost();
    my $client_port    = $client->peerport();

    $data = <$client>;
    chomp($data);
    my $packtype      = ( split /::/, $data )[0];
    my $filenamerecv  = ( split /::/, $data )[1];
    my $md5recv       = ( split /::/, $data )[2];
    my $chunksizerecv = ( split /::/, $data )[3];
    my $chunknumber   = ( split /::/, $data )[4];

    if (    ( $packtype eq "ISEND" )
        and ( $filenamerecv eq $filename )
        and ( $md5recv eq $md5 )
        and ( $chunksizerecv eq $chunksize ) )
    {
        $index = firstidx { $_ eq $chunknumber } @requestedchunkarray;
        if ( $index != -1 ) {
            {
                lock(@requestedchunkarray);
                lock(@requestedchunktimearray);
                $presentchunk = $requestedchunkarray[$index];
                for (
                    $i = $index ;
                    $i < ( scalar @requestedchunkarray ) - 1 ;
                    $i++
                  )
                {
                    $requestedchunkarray[$i] = $requestedchunkarray[ $i + 1 ];
                    $requestedchunktimearray[$i] =
                      $requestedchunktimearray[ $i + 1 ];
                }
                pop(@requestedchunkarray);
                pop(@requestedchunktimearray);
            }
            my $sendmessage = "USEND";
            $newdir    = $filename . $md5 . $chunksize . ".temp";
            $split     = "split";
            $splitfile = $split . $chunknumber;
            open( SPLITFILE, ">$newdir/$splitfile" );

            print $client "$sendmessage\n";

            while (<$client>) {
                print SPLITFILE $_;
            }
            close SPLITFILE;
            shutdown( $client, 2 );
            {
                lock(@presentchunkarray);
                push( @presentchunkarray, $presentchunk );
            }
        }
        else {
            my $sendmessage = "NOSEND";
            print $client "$sendmessage\n";
            shutdown( $client, 2 );
        }
    }
    else {
        shutdown( $client, 2 );
    }

    threads->exit();
    return (0);
}

sub uploadfile() {
    print "Enter file name.\n";
    wait unless my $filename = <>;
    chomp $filename;
    print "Enter chunksize.\n";
    wait unless $chunksize = <>;
    chomp $chunksize;

#this if condition creates a message that indicates upload action and sends it on a multicast socket.
    if ( -e $filename ) {
        my ( $file, $dir, $ext ) = fileparse($filename);
        my $md5 = file_md5_hex($filename);
        open( FILE, $filename );
        my $filesize = -s FILE;
        close FILE;
        splitfile( $filename, $md5, $chunksize );
        {
            lock(@donearray);
            push( @donearray, $file . $md5 . $chunksize . ".temp" );
        }
        my $numberofchunks = ceil( $filesize / $chunksize );
        my $sendmessage =
            "UPLOAD"
          . $delim
          . $file
          . $delim
          . $md5
          . $delim
          . $chunksize
          . $delim
          . $filesize
          . $delim
          . $numberofchunks;
        {
            lock(@presentchunkarray);
            @presentchunkarray = ( 0 .. ( $numberofchunks - 1 ) );
        }
        $multicastsocket->mcast_send($sendmessage)
          || die "CANT SEND MESSAGE: $! ";
    }

    else { print "No such file exists!\n"; }
}

sub downloadfile() {
    print "Enter file name.\n";
    wait unless my $filename = <>;
    chomp $filename;
    print "Enter md5.\n";
    wait unless my $md5 = <>;
    chomp $md5;
    print "Enter chunksize.\n";
    wait unless $chunksize = <>;
    chomp $chunksize;
    print "Enter filesize.\n";
    wait unless $filesize = <>;
    chomp $filesize;
    {
        lock(@notpresentchunkarray);
        @notpresentchunkarray =
          ( 0 .. ( ceil( $filesize / $chunksize ) - 1 ) );
    }
    threads->create( \&sendrequest, $filename, $md5, $chunksize )->detach();
    threads->create( \&receivepackettcp, $filename, $md5, $chunksize )
      ->detach();
    threads->create( \&timeoutrequest )->detach();
    threads->create( \&requestjoinfile, $filename, $md5,
        $chunksize, ceil( $filesize / $chunksize ) )->detach();
}

sub searchfile() {
	print "Enter file name.\n";
	wait unless my $filename = <>;
	chomp $filename;
	my $sendmessage =
            "SEARCH"
          . $delim
          . $filename
          . $delim
          . $searchport
          . $delim
          . $localaddress;
    $multicastsocket->mcast_send($sendmessage);
    $searchthread = threads->create( \&receivesearchpackettcp )->detach();    
    sleep(10);
    kill($searchthread);
}

sub cleanandexit {
    kill($multicastthread);
    lock(@donearray);
    foreach $newdir (@donearray) {
        rmtree($newdir);
    }
    print "\nDirectories cleaned up. Exiting...\n";
    exit;
}
