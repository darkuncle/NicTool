package NicToolServer::Zone::Record;
# ABSTRACT: manage DNS zone records

use strict;

@NicToolServer::Zone::Record::ISA = qw(NicToolServer::Zone);

sub new_zone_record {
    my ( $self, $data ) = @_;

    my $z = $self->find_zone( $data->{nt_zone_id} );
    if ( my $del = $self->get_param_meta( 'nt_zone_id', 'delegate' ) ) {
        return $self->error_response( 404,
            "Not allowed to add records to the delegated zone." )
            unless $del->{zone_perm_add_records};
    }

    # bump the zone's serial number
    my $new_serial = $self->bump_serial( $data->{nt_zone_id}, $z->{serial} );
    $self->exec_query( "UPDATE nt_zone SET serial = ? WHERE nt_zone_id = ?",
        [ $new_serial, $data->{nt_zone_id} ] );

    # build insert query
    my $col_string = 'nt_zone_id';
    my @values = $data->{nt_zone_id};
    foreach my $c ( qw/name ttl description type address weight priority other/ ) {
        next if ! defined $data->{$c};
        if ( $c eq 'type' ) {
            $col_string .= ", type_id";
            $data->{type_id} = $self->get_record_type( { type => $data->{type} } );
            push @values, $data->{type_id};
        }
        else {
            $col_string .= ", $c";
            push @values, $data->{$c};
        };
    };

    my $insertid = $self->exec_query(
        "INSERT INTO nt_zone_record($col_string) VALUES(??)", \@values)
            or return {
                error_code => 600,
                error_msg  => $self->{dbh}->errstr,
            };

    $data->{nt_zone_record_id} = $insertid;
    $self->log_zone_record( $data, 'added', undef, $z );

    $self->_add_matching_spf_record( $data, $col_string, \@values );

    return {
        error_code => 200,
        error_msg => 'OK',
        nt_zone_record_id => $insertid,
    };
}

sub _add_matching_spf_record {
    my ( $self, $data, $col_string, $values ) = @_;

    return if $data->{type} ne 'SPF';  # only try for type SPF

    # see if matching TXT record exists
    my $zrs = $self->exec_query(
    "SELECT nt_zone_record_id FROM nt_zone_record
     WHERE  nt_zone_id=?
       AND  type_id=16
       AND  name=?
       AND address=?",
       [ $data->{nt_zone_id}, $data->{name}, $data->{address}, ],
    );
    return if scalar @$zrs; # already exists

    # make sure the position of type_id column didn't move
    return if $values->[4] != 99;

    $values->[4] = 16;  # switch SPF rec type to TXT type
    $self->exec_query(
        "INSERT INTO nt_zone_record($col_string) VALUES(??)", $values);
};

sub edit_zone_record {
    my ( $self, $data ) = @_;

    my %error = ( 'error_code' => 200, 'error_msg' => 'OK' );

    my $z = $self->find_zone( $data->{nt_zone_id} );

    # bump the zone's serial number
    $self->exec_query( "UPDATE nt_zone SET serial = ? WHERE nt_zone_id = ?",
        [ $self->bump_serial( $data->{nt_zone_id}, $z->{serial} ),
          $data->{nt_zone_id}
        ] );

    my $prev_data = $self->find_zone_record( $data->{nt_zone_record_id} );
    my $log_action = $prev_data->{deleted} ? 'recovered' : 'modified';
    $data->{deleted} = 0;

    my $sql = "UPDATE nt_zone_record SET ";
    my @values;
    my @columns = qw/ name ttl description type address weight priority other
                      location timestamp deleted /;

    my $i = 0;
    foreach my $c ( @columns ) {
        next if ! defined $data->{$c};
        $sql .= "," if $i > 0;
        if ( $c eq 'type' ) {
            $sql .= "type_id = ?";
            push @values, $self->get_record_type( { type=>$data->{$c} } );
        }
        else {
            $sql .= "$c = ?";
            push @values, $data->{$c};
        };
        $i++;
    };

    $sql .= " WHERE nt_zone_record_id = ?";
    push @values, $data->{nt_zone_record_id};

    if ( $self->exec_query( $sql, \@values ) ) {
        $error{nt_zone_record_id} = $data->{nt_zone_record_id};
    }
    else {
        $error{error_code} = 600;
        $error{error_msg}  = $self->{dbh}->errstr;
    }

    $self->log_zone_record( $data, $log_action, $prev_data, $z );

    return \%error;
}

sub delete_zone_record {
    my ( $self, $data, $zone ) = @_;

    if ( my $del = $self->get_param_meta( 'nt_zone_record_id', 'delegate' ) )
    {
        return $self->error_response( 404,
            "Not allowed to delete delegated record." )
            unless $del->{pseudo} && $del->{zone_perm_delete_records};
    }

    my $sql = "SELECT nt_zone_id FROM nt_zone_record WHERE nt_zone_record_id=?";
    my $zrs = $self->exec_query( $sql, $data->{nt_zone_record_id} );

    my $new_serial = $self->bump_serial( $zrs->[0]{nt_zone_id} );
    $sql = "UPDATE nt_zone SET serial = ? WHERE nt_zone_id = ?";
    $self->exec_query( $sql, [ $new_serial, $zrs->[0]{nt_zone_id} ] );

    my %error = ( 'error_code' => 200, 'error_msg' => 'OK' );
    $sql = "UPDATE nt_zone_record set deleted=1 WHERE nt_zone_record_id = ?";

    my $zr_data = $self->find_zone_record( $data->{nt_zone_record_id} );
    $zr_data->{user} = $data->{user};

    $self->exec_query( $sql, $data->{nt_zone_record_id} ) or do {
        $error{error_code} = 600;
        $error{error_msg}  = $self->{dbh}->errstr;
    };

    $self->log_zone_record( $zr_data, 'deleted', {}, $zone );

    return \%error;
}

sub log_zone_record {
    my ( $self, $data, $action, $prev_data, $zone ) = @_;

    $zone ||= $self->find_zone( $data->{nt_zone_id} );

    my $user = $data->{user};
    $data->{nt_user_id} = $user->{nt_user_id};
    $data->{action}     = $action;
    $data->{timestamp}  = time();

    # get zone_id if not provided.
    if ( !$data->{nt_zone_id} ) {
        my $db_data = $self->find_zone_record( $data->{nt_zone_record_id} );
        $data->{nt_zone_id} = $db_data->{nt_zone_id};
    }


    my $col_string = 'nt_zone_id';
    my @values = $data->{nt_zone_id};
    foreach my $c ( qw/ nt_zone_record_id nt_user_id action timestamp name
        ttl description type_id address weight priority other location / )
    {
        next if ! defined $data->{$c};
        $col_string .= ", $c";
        push @values, $data->{$c};
    };

    my $insertid = $self->exec_query(
        "INSERT INTO nt_zone_record_log($col_string) VALUES(??)", \@values);


    $data->{object}       = 'zone_record';
    $data->{log_entry_id} = $insertid;
    $data->{object_id}    = $data->{nt_zone_record_id};

    if ( uc( $data->{type} ) !~ /^MX|SRV$/ ) {   # match MX or SRV
        delete $data->{weight};
    }
    if ( uc( $data->{type} ) ne 'SRV' ) {
        delete $data->{other};
        delete $data->{priority};
    }

    if ( $data->{name} =~ /\.$/ ) {
        $data->{title} = $data->{name};
    }
    else {
        $data->{title} = $data->{name} . "." . $zone->{zone} . ".";
    }

    if ( $action eq 'modified' ) {
        $data->{description} = $self->diff_changes( $data, $prev_data );
    }
    elsif ( $action eq 'deleted' ) {
        $data->{description} = "deleted record from $zone->{zone}";
    }
    elsif ( $action eq 'added' ) {
        $data->{description} = 'initial creation';
    }
    elsif ( $action eq 'recovered' ) {
        $data->{description}
            = "recovered previous settings ($data->{type} $data->{weight} $data->{address})";
    }

    my @g_columns = qw/ nt_user_id timestamp action object object_id log_entry_id title description /;
    $col_string = join(',', @g_columns);
    @values = map( $data->{$_}, @g_columns );
    $self->exec_query( "INSERT INTO nt_user_global_log($col_string) VALUES(??)", \@values );
}

sub get_zone_record {
    my ( $self, $data ) = @_;

    $data->{sortby} ||= 'name';

    my $sql = "SELECT r.*, t.name AS type
    FROM nt_zone_record r
      LEFT JOIN resource_record_type t ON r.type_id=t.id
        WHERE r.nt_zone_record_id=?
         ORDER BY r.$data->{sortby}";
    my $zrs = $self->exec_query( $sql, $data->{nt_zone_record_id} )
        or return {
        error_code => 600,
        error_msg  => $self->{dbh}->errstr,
        };

    my %rv = (
        %{ $zrs->[0] },
        error_code => 200,
        error_msg  => 'OK',
    );

    my $del = $self->get_param_meta( 'nt_zone_record_id', 'delegate' )
        or return \%rv;

# this info comes from NicToolServer.pm when it checks for access perms to the objects
    my %mapping = (
        delegated_by_id   => 'delegated_by_id',
        delegated_by_name => 'delegated_by_name',
        pseudo            => 'pseudo',
        perm_write        => 'delegate_write',
        perm_delete       => 'delegate_delete',
        perm_delegate     => 'delegate_delegate',
        group_name        => 'group_name'
    );
    foreach my $key ( keys %mapping ) {
        $rv{ $mapping{$key} } = $del->{$key};
    }
    return \%rv;
}

sub get_zone_record_log_entry {
    my ( $self, $data ) = @_;

    my $sql = "SELECT zrl.*, t.name AS type
    FROM nt_zone_record_log zrl
      INNER JOIN nt_zone_record zr on zrl.nt_zone_record_id = zr.nt_zone_record_id
      LEFT JOIN resource_record_type t ON zrl.type_id=t.id
          WHERE zrl.nt_zone_record_log_id = ?
            AND zr.nt_zone_record_id=?";

    my $zr_logs
        = $self->exec_query( $sql,
        [ $data->{nt_zone_record_log_id}, $data->{nt_zone_record_id} ] )
        or $self->error_response( 600, $self->{dbh}->errstr );

    $self->error_response( 600, 'No such log entry exists' )
        if !$zr_logs->[0];

    return {
        %{ $zr_logs->[0] },
        error_code => 200,
        error_msg  => 'OK',
    };
}

sub find_zone_record {
    my ( $self, $nt_zone_record_id ) = @_;
    my $sql = "SELECT * FROM nt_zone_record WHERE nt_zone_record_id = ?";
    my $zrs = $self->exec_query( $sql, $nt_zone_record_id );
    return $zrs->[0] || {};
}

sub get_record_type {
    my ( $self, $data ) = @_;
    my $lookup = $data->{type};

    if ( ! $self->{record_types} ) {
        my $sql = "SELECT id,name,description,reverse,forward
            FROM resource_record_type WHERE description IS NOT NULL";
        my $types = $self->exec_query($sql);
        foreach my $t ( @$types ) {
            $self->{record_types}{$t->{id}} = $t;   # index by IETF code #
            $self->{record_types}{$t->{name}} = $t; # index by name (A,MX, )
        }
        $self->{record_types}{'ALL'} = $types;
    };

    if ( $lookup =~ /^\d+$/ ) {   # all numeric
        return $self->{record_types}{$lookup}{name}; # return type name
    }
    elsif ( $lookup eq 'ALL' ) {
        return {
            types      => $self->{record_types}{'ALL'},
            error_code => 200,
            error_msg => 'OK',
        };
    };

    return $self->{record_types}{$lookup}{id};  # got a type, return ID
};

1;

__END__

=head1 SYNOPSIS


=cut

