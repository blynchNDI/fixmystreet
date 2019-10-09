package FixMyStreet::Cobrand::Hackney;
use parent 'FixMyStreet::Cobrand::Whitelabel';

use strict;
use warnings;

sub council_area_id { return 2508; }
sub council_area { return 'Hackney'; }
sub council_name { return 'London Borough of Hackney'; }
sub council_url { return 'hackney'; }

sub example_places {
    return [ 'E8 1DY', 'Hillman Street' ];
}

1;
