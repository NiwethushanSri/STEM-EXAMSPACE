# @stem/shared

Shared TypeScript for web and mobile: Supabase client, role routing, Edge Function callers, types.

## PostgREST embeds

`profiles` and `student_details` have more than one relationship, so an embed must name the foreign key:

```ts
client.from("profiles").select("id, student_details!profile_id(index_number, school)");
```

## Notes

- `callFunction` never throws; it returns `{ data }` or `{ error: { code, message } }`.
- `bannedMessage` is the copy for the GoTrue "banned" sign-in error (suspended staff).
- `database.types.ts` is generated: `npx supabase gen types typescript --linked > packages/shared/src/database.types.ts`.
