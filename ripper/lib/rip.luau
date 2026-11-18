--!nonstrict
-- Detached job: video(s) -> AVIF frames, straight from ffmpeg (libaom still pictures, no PNG step).
-- Run as: sh -c RIP ripper-job args.
-- $1 video or folder of videos  $2 output base  $3 project  $4 fps  $5 skip start  $6 skip end
-- $7 filter 0/1  $8 tolerance  $9 avif quality 0-100  ${10} progress dir  ${11} folder order: date or name
return [==[
for c in ffmpeg ffprobe; do
  command -v "$c" >/dev/null || { notify-send -a Ripper -u critical "Ripper" "$c is not installed"; exit 1; }
done
video=$1 fps=$4 ss=$5 se=$6 filter=$7 tol=$8 q=$9 pd=${10} order=${11:-date}
mkdir -p "$pd"; rm -f "$pd/total" "$pd/start" "$pd/phase" "$pd/dir" "$pd/count"; echo 0 > "$pd/count"
d="$2/$3"; n=2
while [ -e "$d" ]; do d="$2/$3-$n"; n=$((n+1)); done
mkdir -p "$d/avif" || exit 1
echo "$d" > "$pd/dir"
vids=$(mktemp)
cleanup() { rm -f "$vids"; }
fail() {
  rm -f "$pd/dir"
  notify-send -a Ripper -u critical "Ripper failed" "$1"
  cleanup; rmdir "$d/avif" "$d" 2>/dev/null; exit 1
}
trap 'cleanup; rm -f "$pd/start"; exit 1' TERM INT
# A folder is read by creation date (modification date when the filesystem has none) or by file name.
if [ -d "$video" ]; then
  find "$video" -maxdepth 1 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mov' -o -iname '*.avi' \) -printf '%B@ %T@ %p\n' \
    | awk '{t=$1; if (t==0 || t=="") t=$2; sub(/^[^ ]+ [^ ]+ /, ""); printf "%s\t%s\n", t, $0}' > "$vids.all"
  if [ "$order" = name ]; then cut -f2- "$vids.all" | sort -V > "$vids"; else sort -n "$vids.all" | cut -f2- > "$vids"; fi
  rm -f "$vids.all"
else
  printf '%s\n' "$video" > "$vids"
fi
[ -e "$video" ] || fail "$video does not exist"
[ -s "$vids" ] || fail "No videos found in $video"
total=0
while IFS= read -r v; do
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$v" 2>/dev/null)
  total=$(awk -v t="$total" -v d="${dur:-0}" -v a="$ss" -v b="$se" -v f="$fps" 'BEGIN{x=d-a-b; if (x<0) x=0; y=x*f; c=int(y); if (c<y) c++; print t+c}')
done < "$vids"
[ "$total" -gt 0 ] || fail "Nothing to convert: unreadable video, or nothing left after the skips"
echo "$total" > "$pd/total"; date +%s > "$pd/start"; echo convert > "$pd/phase"
vf="fps=$fps"
if [ "$filter" = 1 ]; then
  vf="$vf,signalstats,metadata=select:key=lavfi.signalstats.YMAX:value=$((16+tol)):function=greater,metadata=select:key=lavfi.signalstats.YMIN:value=$((235-tol)):function=less"
fi
crf=$(( (100 - q) * 63 / 100 ))
# Progress counter for the panel.
( while :; do find "$d/avif" -name '*.avif' | wc -l > "$pd/count"; sleep 1; done ) &
wd=$!
trap 'kill "$wd" 2>/dev/null; cleanup; rm -f "$pd/start"; exit 1' TERM INT

bad_videos=0
while IFS= read -r v; do
  offset=$(find "$d/avif" -name '*.avif' | wc -l)
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$v" 2>/dev/null)
  dur_eff=$(awk -v d="${dur:-0}" -v a="$ss" -v b="$se" 'BEGIN{x=d-a-b; print (x>0?x:0)}')
  [ "$dur_eff" = 0 ] && continue
  # One AVIF per frame: the segment muxer cuts after every frame (segment time is below the frame spacing).
  ffmpeg -nostdin -v error -ss "$ss" -i "$v" -t "$dur_eff" -vf "$vf" -fps_mode vfr \
    -c:v libaom-av1 -still-picture 1 -crf "$crf" -b:v 0 -cpu-used 6 -row-mt 1 \
    -f segment -segment_format avif -segment_time 0.01 -reset_timestamps 1 -segment_start_number $((offset+1)) \
    "$d/avif/${3}_%06d.avif" || bad_videos=$((bad_videos+1))
done < "$vids"
kill "$wd" 2>/dev/null

n=$(find "$d/avif" -name '*.avif' | wc -l)
echo "$n" > "$pd/count"; echo "$n" > "$pd/total"
cleanup
[ "$n" -gt 0 ] || fail "No frames written (unreadable video, or every frame was black or white)"
if [ "$bad_videos" -eq 0 ]; then
  notify-send -a Ripper "Ripper" "$n frames written to $d/avif"
else
  notify-send -a Ripper -u critical "Ripper" "$n frames written to $d/avif ($bad_videos unreadable videos)"
fi
rm -f "$pd/phase"]==]
