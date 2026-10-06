# AI Disclosure

This document is to track the contributions made by AI throughout the development process

## 10/6/2026
* **Brody Blask** - I designed the Supabase migration doc that outlines table schema, functions, permissions, and row level security, then had Claude Opus 5.5 on Medium effort to review my design. It pointed out that event creators did not automatically RSVP as going to their own event, and that creators had the option to un-RSVP to their own event. I had Claude add the automatic RSVP functionality, and prevent creators from un-RSVPing, making them cancel the event instead