package MT::Plugin::Jev::Content;

use strict;
use warnings;
use HTML::Parser;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8 decode FB_CROAK is_utf8);
use MT::Plugin::Jev;

sub plain_text {
    my ($value) = @_;
    return '' unless defined $value;
    if (ref $value eq 'ARRAY') {
        return [map { plain_text($_) } @$value];
    }
    if (ref $value eq 'HASH') {
        return { map { $_ => plain_text($value->{$_}) } keys %$value };
    }
    $value = decode('UTF-8', $value, FB_CROAK) unless is_utf8($value);
    return "$value" unless $value =~ /<\/?[a-zA-Z!]/;
    my ($text, $hidden) = ('', 0);
    my $parser = HTML::Parser->new(api_version => 3);
    $parser->handler(start => sub {
        my ($tag, $attr) = @_;
        $hidden++ if $tag eq 'script' || $tag eq 'style';
        return if $hidden;
        $text .= ' ' if $tag =~ /\A(?:p|div|br|li|tr|td|th|h[1-6]|section|blockquote)\z/;
        $text .= ' ' . $attr->{alt} . ' ' if $tag eq 'img' && defined $attr->{alt};
    }, 'tagname, attr');
    $parser->handler(end => sub {
        my ($tag) = @_;
        if ($tag eq 'script' || $tag eq 'style') {
            $hidden-- if $hidden;
        }
        $text .= ' ' if !$hidden && $tag =~ /\A(?:p|div|li|tr|td|th|h[1-6]|section|blockquote)\z/;
    }, 'tagname');
    $parser->handler(text => sub { $text .= $_[0] unless $hidden }, 'dtext');
    $parser->parse($value);
    $parser->eof;
    $text =~ s/\s+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    return $text;
}

sub fields {
    my ($class, $app, $object, $columns, $api, %options) = @_;
    my ($ct, %field_by_id);
    if ($object->isa('MT::ContentData')) {
        $ct = $object->content_type;
        %field_by_id = map { $_->{id} => $_ } @{ $ct->searchable_fields };
    }
    my @fields;
    for my $column (@$columns) {
        my ($label, $value);
        if ($column =~ /\A__field:(\d+)\z/) {
            my $field = $field_by_id{$1} or next;
            $label = $field->{options}{label} || $field->{name};
            $value = _field_value($app, $object, $field, $object->data->{$field->{id}}, %options);
        } elsif ($column eq 'label' && $ct && $ct->data_label) {
            my ($field) = grep { $_->{unique_id} eq $ct->data_label } @{ $ct->fields };
            $label = $options{index} ? 'label' : $app->translate('Data Label');
            $value = $field ? _field_value($app, $object, $field, $object->data->{$field->{id}}, %options) : $object->label;
        } else {
            next unless exists $api->{search_cols}{$column} && $column ne 'plugin';
            $label = $api->{search_cols}{$column};
            $label = $options{index} ? $column : ref $label eq 'CODE' ? $label->() : $app->translate($label);
            $value = plain_text($object->column($column));
        }
        push @fields, { name => $column, label => $label, value => $value };
    }
    return _unicode(\@fields);
}

sub _unicode {
    my ($value) = @_;
    return [map { _unicode($_) } @$value] if ref $value eq 'ARRAY';
    return {map { $_ => _unicode($value->{$_}) } keys %$value} if ref $value eq 'HASH';
    return $value if !defined $value || is_utf8($value);
    return decode('UTF-8', $value, FB_CROAK);
}

sub _field_value {
    my ($app, $object, $field, $value, %options) = @_;
    return '' unless defined $value;
    my $type = $field->{type};
    if ($type =~ /\A(?:select_box|radio_button|checkboxes)\z/) {
        my %labels = map { $_->{value} => $_->{label} } @{ $field->{options}{values} || [] };
        return [map { +{ value => $_, label => $labels{$_} // '' } }
            ref $value eq 'ARRAY' ? @$value : ($value)];
    }
    my %references = (categories => 'category', tags => 'tag', asset => 'asset',
        asset_audio => 'asset', asset_video => 'asset', asset_image => 'asset', content_type => 'content_data');
    if (my $model = $references{$type}) {
        my @values;
        for my $id (ref $value eq 'ARRAY' ? @$value : ($value)) {
            next unless defined $id && $id =~ /\A\d+\z/;
            if ($options{index} && ($model eq 'asset' || $model eq 'content_data')) {
                push @values, {id => 0 + $id};
                next;
            }
            my $ref = $app->model($model)->load($id) or next;
            if ($ref->has_column('blog_id')) {
                next unless $ref->blog_id == $object->blog_id;
            }
            if (($model eq 'asset' || $model eq 'content_data') && !$app->user->is_superuser) {
                my $api = $app->registry('search_apis')->{$model} or next;
                my $check = $app->handler_to_coderef($api->{perm_check}) or next;
                next unless $check->($ref);
            }
            push @values, { id => 0 + $id, label => plain_text($model eq 'tag' ? $ref->name : $ref->label) };
        }
        return \@values;
    }
    return plain_text($value);
}

sub columns {
    my ($class, $object, $api) = @_;
    my @columns = grep { $_ ne 'plugin' } keys %{ $api->{search_cols} };
    push @columns, map { '__field:' . $_->{id} } @{ $object->content_type->searchable_fields }
        if $object->isa('MT::ContentData');
    return [sort @columns];
}

sub shorten_index_text {
    my ($class, $text, $ratio) = @_;
    my $json = JSON::PP->new->canonical;
    my $fields = $json->decode($text);
    my $remaining = int(length($text) * (1 - $ratio)) + 1;
    # Work on a decoded copy. Keep titles/data labels until other values
    # have been exhausted; within each group trim the longest value first.
    for my $primary (0, 1) {
        my @values = map { _embedding_values(\$_->{value}) }
            grep { (($_->{name} eq 'title' || $_->{name} eq 'label') ? 1 : 0) == $primary } @$fields;
        for my $value (sort { length($$b) <=> length($$a) } @values) {
            last unless $remaining > 0;
            my $remove = length($$value) < $remaining ? length($$value) : $remaining;
            substr($$value, length($$value) - $remove) = '';
            $remaining -= $remove;
        }
    }
    my $shorter = $json->encode($fields);
    return length($shorter) < length($text) ? $shorter : undef;
}

sub _embedding_values {
    my ($value) = @_;
    return map { _embedding_values(\$_) } @{$$value} if ref $$value eq 'ARRAY';
    return map { _embedding_values(\$$value->{$_}) } sort keys %{$$value} if ref $$value eq 'HASH';
    return !ref $$value && defined $$value ? ($value) : ();
}

sub index_document {
    my ($class, $object, $api) = @_;
    # Read the core column definitions outside CMS without populating MT's
    # cached CMS registry with permission closures bound to a dummy user.
    require MT::App::CMS;
    my $app = MT->app;
    $app = bless {}, 'MT::App::CMS' unless $app->can('user');
    my $type = $object->isa('MT::ContentData') ? 'content_data' : $object->class;
    if (!$api) {
        require MT::CMS::Search;
        $api = $app->isa('MT::App::CMS') && $app->user
            ? $app->registry('search_apis')->{$type}
            : MT::CMS::Search::core_search_apis($app)->{$type};
    }
    my $fields = $class->fields($app, $object, $class->columns($object, $api), $api, index => 1);
    my $json = JSON::PP->new->canonical;
    my $has_text;
    for my $field (@$fields) {
        my $value = $field->{value};
        $has_text ||= ref $value ? $json->encode($value) !~ /\A(?:\[\]|\{\})\z/ : $value =~ /\S/;
    }
    my $text = $has_text ? $json->encode($fields) : '';
    return {text => $text, hash => sha256_hex(encode_utf8($text))};
}

1;
