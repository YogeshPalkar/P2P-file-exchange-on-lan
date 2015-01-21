use File::Path;
use File::chmod;
sub joinfile() {
    my $filename       = $_[0];
    my $md5            = $_[1];
    my $chunksize      = $_[2];
    my $numberofchunks = $_[3];
    $newdir = $filename . $md5 . $chunksize . ".temp";
    open( FILE, '>', $filename );
    $split = "split";
    for ( $i = 0 ; $i < $numberofchunks ; $i++ ) {
        $splitfile = $split . $i;
        open( SPLITFILE, "$newdir/$splitfile" );
        while (<SPLITFILE>) {
            print FILE $_;
        }
        close SPLITFILE;
    }
    close FILE;
    chmod( 0777, $filename);
}
1;
