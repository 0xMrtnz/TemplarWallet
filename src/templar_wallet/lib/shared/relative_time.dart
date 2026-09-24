/// How long ago something happened, in the fewest characters that stay true.
///
/// Used where a timestamp rides inside a one-line subtitle (the Dashboard's
/// activity rows) and a full date would push the counterparty off the row.
/// Pure — [now] is injectable so the tests do not race the clock.
String relativeTimeShort(DateTime time, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final d = ref.difference(time);

  // A clock skew (a block stamped a minute into the future) reads as "now",
  // never as a negative age.
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  if (d.inDays < 365) return '${time.day} ${_months[time.month - 1]}';
  return '${time.day} ${_months[time.month - 1]} ${time.year}';
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
