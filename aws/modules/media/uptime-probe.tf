# The object the uptime probe fetches through the distribution, under media/ like every HLS object, so it takes the
# same bucket policy and cache behavior. no-store leaves an edge only the minimum TTL of the cache policy (1 second),
# so each probe reaches the bucket and a broken origin shows at once.
resource "aws_s3_object" "uptime_probe" {
  bucket        = aws_s3_bucket.this["media"].bucket
  key           = "media/uptime-probe.txt"
  content       = "ok\n"
  content_type  = "text/plain"
  cache_control = "no-store"
}
