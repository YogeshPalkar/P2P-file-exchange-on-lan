sub splitfile() {
    my $filename  = $_[0];
    my $md5       = $_[1];
    my $chunksize = $_[2];
    $newdir = $filename . $md5 . $chunksize . ".temp";
    mkdir $newdir, 0777;
    open( FILE, $filename );
    $filesize = -s FILE;
    $split = "split";
    for ( $i = 0 ; $i * $chunksize < $filesize ; $i++ ) {
        $splitfile = $split . $i;
        open( SPLITFILE, ">$newdir/$splitfile" );
        if ( $chunksize * ( $i + 1 ) < $filesize ) {
            read( FILE, $file_contents, $chunksize );
            print SPLITFILE $file_contents;
            close SPLITFILE;
        }
        else {
            read( FILE, $file_contents, $filesize - ( $chunksize * $i ) );
            print SPLITFILE $file_contents;
            close SPLITFILE;
        }
    }
    close FILE;
}
1;
