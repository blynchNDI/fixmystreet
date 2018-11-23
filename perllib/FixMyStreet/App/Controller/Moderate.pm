package FixMyStreet::App::Controller::Moderate;

use Moose;
use namespace::autoclean;
use Algorithm::Diff;
BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

FixMyStreet::App::Controller::Moderate - process a moderation event

=head1 DESCRIPTION

The intent of this is that council users will be able to moderate reports
by themselves, but without requiring access to the full admin panel.

From a given report page, an authenticated user will be able to press
the "moderate" button on report and any updates to bring up a form with
data to change.

(Authentication requires:

  - user to be from_body
  - user to have a "moderate" record in user_body_permissions

The original and previous data of the report is stored in
moderation_original_data, so that it can be reverted/consulted if required.
All moderation events are stored in admin_log.

=head1 SEE ALSO

DB tables:

    AdminLog
    ModerationOriginalData
    UserBodyPermissions

=cut

sub moderate : Chained('/') : PathPart('moderate') : CaptureArgs(0) { }

sub report : Chained('moderate') : PathPart('report') : CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    my $problem = $c->model('DB::Problem')->find($id);
    $c->detach unless $problem;

    my $cobrand_base = $c->cobrand->base_url_for_report( $problem );
    my $report_uri = $cobrand_base . $problem->url;
    $c->stash->{cobrand_base} = $cobrand_base;
    $c->stash->{report_uri} = $report_uri;
    $c->res->redirect( $report_uri ); # this will be the final endpoint after all processing...

    # ... and immediately, if the user isn't logged in
    $c->detach unless $c->user_exists;

    $c->forward('/auth/check_csrf_token');

    $c->stash->{history} = $problem->new_related( moderation_original_data => {
        title => $problem->title,
        detail => $problem->detail,
        photo => $problem->photo,
        anonymous => $problem->anonymous,
        longitude => $problem->longitude,
        latitude => $problem->latitude,
        category => $problem->category,
        $problem->extra ? (extra => $problem->extra) : (),
    });
    $c->stash->{original} = $problem->moderation_original_data || $c->stash->{history};
    $c->stash->{problem} = $problem;
    $c->stash->{moderation_reason} = $c->get_param('moderation_reason') // '';
}

sub moderate_report : Chained('report') : PathPart('') : Args(0) {
    my ($self, $c) = @_;

    my $problem = $c->stash->{problem};

    # Make sure user can moderate this report
    $c->detach unless $c->user->can_moderate($problem);

    $c->forward('report_moderate_hide');

    my @types = grep $_,
        ($c->user->can_moderate_title($problem, 1)
            ? $c->forward('moderate_text', [ 'title' ])
            : ()),
        $c->forward('moderate_text', [ 'detail' ]),
        $c->forward('moderate_boolean', [ 'anonymous', 'show_name' ]),
        $c->forward('moderate_boolean', [ 'photo' ]),
        $c->forward('moderate_location'),
        $c->forward('moderate_category'),
        $c->forward('moderate_extra');

    # Deal with possible photo changes. If a moderate form uses a standard
    # photo upload field (with upload_fileid, label and file upload handlers),
    # this will allow photos to be changed, not just switched on/off. You will
    # probably want a hidden field with problem_photo=1 to skip that check.
    my $photo_edit_form = defined $c->get_param('photo1');
    if ($photo_edit_form) {
        $c->forward('/photo/process_photo');
        if ( my $photo_error = delete $c->stash->{photo_error} ) {
            $c->flash->{moderate_errors} ||= [];
            push @{ $c->flash->{moderate_errors} }, $photo_error;
        } else {
            my $fileid = $c->stash->{upload_fileid};
            if ($fileid ne $problem->photo) {
                $problem->get_photoset->delete_cached;
                $problem->update({ photo => $fileid || undef });
                push @types, 'photo';
            }
        }
    }

    $c->detach( 'report_moderate_audit', \@types )
}

sub moderating_user_name {
    my $user = shift;
    return $user->from_body ? $user->from_body->name : _('an administrator');
}

sub moderate_log_entry : Private {
    my ($self, $c, $object_type, @types) = @_;

    my $user = $c->user->obj;
    my $reason = $c->stash->{'moderation_reason'};
    my $object = $object_type eq 'update' ? $c->stash->{comment} : $c->stash->{problem};

    my $types_csv = join ', ' => @types;

    # We attach the log to the moderation entry if present, or the object if not (hiding)
    $c->model('DB::AdminLog')->create({
        action => 'moderation',
        user => $user,
        admin_user => moderating_user_name($user),
        object_id => $c->stash->{history}->id || $object->id,
        object_type => $c->stash->{history}->id ? 'moderation' : $object_type,
        reason => (sprintf '%s (%s)', $reason, $types_csv),
    });
}

sub report_moderate_audit : Private {
    my ($self, $c, @types) = @_;

    my $problem = $c->stash->{problem} or die;

    $c->forward('moderate_log_entry', [ 'problem', @types ]);

    if ($problem->user->email_verified && $c->cobrand->send_moderation_notifications) {
        my $token = $c->model("DB::Token")->create({
            scope => 'moderation',
            data => { id => $problem->id }
        });

        my $types_csv = join ', ' => @types;
        $c->send_email( 'problem-moderated.txt', {
            to => [ [ $problem->user->email, $problem->name ] ],
            types => $types_csv,
            user => $problem->user,
            problem => $problem,
            report_uri => $c->stash->{report_uri},
            report_complain_uri => $c->stash->{cobrand_base} . '/contact?m=' . $token->token,
            moderated_data => $c->stash->{history},
        });
    }
}

sub report_moderate_hide : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;

    if ($c->get_param('problem_hide')) {

        $problem->update({ state => 'hidden' });
        $problem->get_photoset->delete_cached;

        $c->res->redirect( '/' ); # Go directly to front-page
        $c->detach( 'report_moderate_audit', ['hide'] ); # break chain here.
    }
}

sub moderate_text : Private {
    my ($self, $c, $thing) = @_;

    my $object = $c->stash->{comment} || $c->stash->{problem};
    my $param = $c->stash->{comment} ? 'update_' : 'problem_';

    my $thing_for_original_table = $thing;
    # Update 'text' field is stored in original table's 'detail' field
    $thing_for_original_table = 'detail' if $c->stash->{comment} && $thing eq 'text';

    my $old = $object->$thing;
    my $original_thing = $c->stash->{original}->$thing_for_original_table;

    my $new = $c->get_param($param . 'revert_' . $thing) ?
        $original_thing
        : $c->get_param($param . $thing);

    if ($new ne $old) {
        $c->stash->{history}->insert;
        $object->update({ $thing => $new });
        return $thing_for_original_table;
    }

    return;
}

sub moderate_boolean : Private {
    my ( $self, $c, $thing, $reverse ) = @_;

    my $object = $c->stash->{comment} || $c->stash->{problem};
    my $param = $c->stash->{comment} ? 'update_' : 'problem_';
    my $original = $c->stash->{original}->photo;

    return if $thing eq 'photo' && !$original;

    my $new;
    if ($reverse) {
        $new = $c->get_param($param . $reverse) ? 0 : 1;
    } else {
        $new = $c->get_param($param . $thing) ? 1 : 0;
    }
    my $old = $object->$thing ? 1 : 0;

    if ($new != $old) {
        $c->stash->{history}->insert;
        if ($thing eq 'photo') {
            $object->update({ $thing => $new ? $original : undef });
        } else {
            $object->update({ $thing => $new });
        }
        return $thing;
    }
    return;
}

sub moderate_extra : Private {
    my ($self, $c) = @_;

    my $object = $c->stash->{comment} || $c->stash->{problem};

    my $changed;
    my @extra = grep { /^extra\./ } keys %{$c->req->params};
    foreach (@extra) {
        my ($field_name) = /extra\.(.*)/;
        my $old = $object->get_extra_metadata($field_name) || '';
        my $new = $c->get_param($_);
        if ($new ne $old) {
            $object->set_extra_metadata($field_name, $new);
            $changed = 1;
        }
    }
    if ($changed) {
        $c->stash->{history}->insert;
        $object->update;
        return 'extra';
    }
}

sub moderate_location : Private {
    my ($self, $c) = @_;

    my $problem = $c->stash->{problem};

    my $moved = $c->forward('/admin/report_edit_location', [ $problem ]);
    if (!$moved) {
        # New lat/lon isn't valid, show an error
        $c->flash->{moderate_errors} ||= [];
        push @{ $c->flash->{moderate_errors} }, _('Invalid location. New location must be covered by the same council.');
        return;
    }

    if ($moved == 2) {
        $c->stash->{history}->insert;
        $problem->update;
        return 'location';
    }
}

# No update left at present
sub moderate_category : Private {
    my ($self, $c) = @_;

    return unless $c->get_param('category');

    # The admin category editing needs to know all the categories etc
    $c->forward('/admin/categories_for_point');

    my $problem = $c->stash->{problem};

    my $changed = $c->forward( '/admin/report_edit_category', [ $problem, 1 ] );
    # It might need to set_report_extras in future
    if ($changed) {
        $c->stash->{history}->insert;
        $problem->update;
        return 'category';
    }
}

sub update : Chained('report') : PathPart('update') : CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    my $comment = $c->stash->{problem}->comments->find($id);

    # Make sure user can moderate this update
    $c->detach unless $comment && $c->user->can_moderate($comment);

    $c->stash->{history} = $comment->new_related( moderation_original_data => {
        detail => $comment->text,
        photo => $comment->photo,
        anonymous => $comment->anonymous,
        $comment->extra ? (extra => $comment->extra) : (),
    });
    $c->stash->{comment} = $comment;
    $c->stash->{original} = $comment->moderation_original_data || $c->stash->{history};
}

sub moderate_update : Chained('update') : PathPart('') : Args(0) {
    my ($self, $c) = @_;

    $c->forward('update_moderate_hide');

    my @types = grep $_,
        $c->forward('moderate_text', [ 'text' ]),
        $c->forward('moderate_boolean', [ 'anonymous', 'show_name' ]),
        $c->forward('moderate_extra'),
        $c->forward('moderate_boolean', [ 'photo' ]);

    $c->detach('moderate_log_entry', [ 'update', @types ]);
}

sub update_moderate_hide : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $comment = $c->stash->{comment} or die;

    if ($c->get_param('update_hide')) {
        $comment->hide;
        $c->detach('moderate_log_entry', [ 'update', 'hide' ]); # break chain here.
    }
    return;
}

__PACKAGE__->meta->make_immutable;

1;
