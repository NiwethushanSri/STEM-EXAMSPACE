
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "attendance": {
                  Row: {
                    "exam_id": string,"marked_at": string,"marked_by": string | null,"status": Database["public"]['Enums']["attendance_status"],"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "exam_id": string,"marked_at"?: string,"marked_by"?: string | null,"status": Database["public"]['Enums']["attendance_status"],"student_id": string
                  }
                  Update: {
                    "exam_id"?: string,"marked_at"?: string,"marked_by"?: string | null,"status"?: Database["public"]['Enums']["attendance_status"],"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "attendance_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attendance_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attendance_marked_by_fkey"
      columns: ["marked_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attendance_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"audit_log": {
                  Row: {
                    "action": string,"actor_id": string | null,"created_at": string,"id": number,"reason": string | null,"target_id": string | null,"target_type": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "action": string,"actor_id"?: string | null,"created_at"?: string,"id"?: never,"reason"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                  }
                  Update: {
                    "action"?: string,"actor_id"?: string | null,"created_at"?: string,"id"?: never,"reason"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"bookings": {
                  Row: {
                    "amount_pence": number,"booked_by": string | null,"centre_id": string | null,"created_at": string,"exam_id": string,"hold_expires_at": string | null,"id": string,"notes": string | null,"paid_at": string | null,"paid_offline": boolean,"refund_due": boolean,"refunded_pence": number,"sitting": Database["public"]['Enums']["sitting_mode"],"status": Database["public"]['Enums']["booking_status"],"stripe_checkout_session_id": string | null,"stripe_payment_intent_id": string | null,"student_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_pence": number,"booked_by"?: string | null,"centre_id"?: string | null,"created_at"?: string,"exam_id": string,"hold_expires_at"?: string | null,"id"?: string,"notes"?: string | null,"paid_at"?: string | null,"paid_offline"?: boolean,"refund_due"?: boolean,"refunded_pence"?: number,"sitting": Database["public"]['Enums']["sitting_mode"],"status": Database["public"]['Enums']["booking_status"],"stripe_checkout_session_id"?: string | null,"stripe_payment_intent_id"?: string | null,"student_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "amount_pence"?: number,"booked_by"?: string | null,"centre_id"?: string | null,"created_at"?: string,"exam_id"?: string,"hold_expires_at"?: string | null,"id"?: string,"notes"?: string | null,"paid_at"?: string | null,"paid_offline"?: boolean,"refund_due"?: boolean,"refunded_pence"?: number,"sitting"?: Database["public"]['Enums']["sitting_mode"],"status"?: Database["public"]['Enums']["booking_status"],"stripe_checkout_session_id"?: string | null,"stripe_payment_intent_id"?: string | null,"student_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "bookings_booked_by_fkey"
      columns: ["booked_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_centre_exam_fkey"
      columns: ["centre_id","exam_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id","exam_id"]
    },{
      foreignKeyName: "bookings_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"collection_counts": {
                  Row: {
                    "booking_id": string,"exam_id": string,"extra_sheets": number,"recorded_at": string,"recorded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id": string,"exam_id": string,"extra_sheets": number,"recorded_at"?: string,"recorded_by": string
                  }
                  Update: {
                    "booking_id"?: string,"exam_id"?: string,"extra_sheets"?: number,"recorded_at"?: string,"recorded_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "collection_counts_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: true
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_counts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_counts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"collection_manifests": {
                  Row: {
                    "centre_id": string,"created_at": string,"created_by": string,"exam_id": string,"id": string,"number": string
                  }
                  ComputedFields: never
                  Insert: {
                    "centre_id": string,"created_at"?: string,"created_by": string,"exam_id": string,"id"?: string,"number": string
                  }
                  Update: {
                    "centre_id"?: string,"created_at"?: string,"created_by"?: string,"exam_id"?: string,"id"?: string,"number"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "collection_manifests_centre_id_fkey"
      columns: ["centre_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_manifests_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_manifests_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"custody_events": {
                  Row: {
                    "at": string,"batch_id": string | null,"centre_id": string,"exam_id": string,"from_staff": string | null,"id": string,"location": string,"manifest_id": string | null,"note": string | null,"recorded_by": string,"seq": number,"step": string,"to_staff": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "at"?: string,"batch_id"?: string | null,"centre_id": string,"exam_id": string,"from_staff"?: string | null,"id"?: string,"location": string,"manifest_id"?: string | null,"note"?: string | null,"recorded_by": string,"seq"?: never,"step": string,"to_staff"?: string | null
                  }
                  Update: {
                    "at"?: string,"batch_id"?: string | null,"centre_id"?: string,"exam_id"?: string,"from_staff"?: string | null,"id"?: string,"location"?: string,"manifest_id"?: string | null,"note"?: string | null,"recorded_by"?: string,"seq"?: never,"step"?: string,"to_staff"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "custody_events_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "scan_batches"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_centre_id_fkey"
      columns: ["centre_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_from_staff_fkey"
      columns: ["from_staff"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_manifest_id_fkey"
      columns: ["manifest_id"]
isOneToOne: false
      referencedRelation: "collection_manifests"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_to_staff_fkey"
      columns: ["to_staff"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"exam_centres": {
                  Row: {
                    "created_at": string,"exam_id": string,"id": string,"register_closed_at": string | null,"removed_at": string | null,"room": string,"seat_limit": number,"venue_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"exam_id": string,"id"?: string,"register_closed_at"?: string | null,"removed_at"?: string | null,"room": string,"seat_limit": number,"venue_id": string
                  }
                  Update: {
                    "created_at"?: string,"exam_id"?: string,"id"?: string,"register_closed_at"?: string | null,"removed_at"?: string | null,"room"?: string,"seat_limit"?: number,"venue_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "exam_centres_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_centres_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_centres_venue_id_fkey"
      columns: ["venue_id"]
isOneToOne: false
      referencedRelation: "venues"
      referencedColumns: ["id"]
    }
                  ]
                },"exam_papers": {
                  Row: {
                    "byte_size": number,"corrected_notified_at": string | null,"exam_id": string,"id": string,"kind": Database["public"]['Enums']["paper_kind"],"page_count": number,"pages_reviewed_at": string | null,"replace_reason": string | null,"storage_path": string,"superseded_at": string | null,"title": string,"uploaded_at": string,"uploaded_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "byte_size": number,"corrected_notified_at"?: string | null,"exam_id": string,"id"?: string,"kind": Database["public"]['Enums']["paper_kind"],"page_count": number,"pages_reviewed_at"?: string | null,"replace_reason"?: string | null,"storage_path": string,"superseded_at"?: string | null,"title": string,"uploaded_at"?: string,"uploaded_by"?: string | null,"version": number
                  }
                  Update: {
                    "byte_size"?: number,"corrected_notified_at"?: string | null,"exam_id"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["paper_kind"],"page_count"?: number,"pages_reviewed_at"?: string | null,"replace_reason"?: string | null,"storage_path"?: string,"superseded_at"?: string | null,"title"?: string,"uploaded_at"?: string,"uploaded_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "exam_papers_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_papers_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_papers_uploaded_by_fkey"
      columns: ["uploaded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"exams": {
                  Row: {
                    "allowed_materials": string | null,"booking_deadline": string,"created_at": string,"created_by": string | null,"currency": string,"duration_minutes": number,"exam_code": string,"format": Database["public"]['Enums']["exam_format"],"home_rules": string | null,"id": string,"paper": string,"price_confirmed": boolean,"price_pence": number,"release_held": boolean,"release_minutes_before": number,"release_notified_at": string | null,"released_early_at": string | null,"spare_pages": number,"starts_at": string,"status": Database["public"]['Enums']["exam_status"],"subject_id": number,"title": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "allowed_materials"?: string | null,"booking_deadline": string,"created_at"?: string,"created_by"?: string | null,"currency"?: string,"duration_minutes": number,"exam_code": string,"format": Database["public"]['Enums']["exam_format"],"home_rules"?: string | null,"id"?: string,"paper": string,"price_confirmed"?: boolean,"price_pence": number,"release_held"?: boolean,"release_minutes_before"?: number,"release_notified_at"?: string | null,"released_early_at"?: string | null,"spare_pages"?: number,"starts_at": string,"status"?: Database["public"]['Enums']["exam_status"],"subject_id": number,"title": string,"updated_at"?: string
                  }
                  Update: {
                    "allowed_materials"?: string | null,"booking_deadline"?: string,"created_at"?: string,"created_by"?: string | null,"currency"?: string,"duration_minutes"?: number,"exam_code"?: string,"format"?: Database["public"]['Enums']["exam_format"],"home_rules"?: string | null,"id"?: string,"paper"?: string,"price_confirmed"?: boolean,"price_pence"?: number,"release_held"?: boolean,"release_minutes_before"?: number,"release_notified_at"?: string | null,"released_early_at"?: string | null,"spare_pages"?: number,"starts_at"?: string,"status"?: Database["public"]['Enums']["exam_status"],"subject_id"?: number,"title"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "exams_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exams_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "subjects"
      referencedColumns: ["id"]
    }
                  ]
                },"home_submissions": {
                  Row: {
                    "blank_confirmed": (number)[],"booking_id": string,"checked_at": string | null,"id": string,"late": boolean,"rejected_reason": string | null,"replaces_all": boolean,"seq": number,"state": Database["public"]['Enums']["submission_state"],"submitted_at": string | null,"submitted_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "blank_confirmed"?: (number)[],"booking_id": string,"checked_at"?: string | null,"id"?: string,"late"?: boolean,"rejected_reason"?: string | null,"replaces_all"?: boolean,"seq": number,"state"?: Database["public"]['Enums']["submission_state"],"submitted_at"?: string | null,"submitted_by"?: string | null
                  }
                  Update: {
                    "blank_confirmed"?: (number)[],"booking_id"?: string,"checked_at"?: string | null,"id"?: string,"late"?: boolean,"rejected_reason"?: string | null,"replaces_all"?: boolean,"seq"?: number,"state"?: Database["public"]['Enums']["submission_state"],"submitted_at"?: string | null,"submitted_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "home_submissions_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    }
                  ]
                },"index_counters": {
                  Row: {
                    "last": number,"year": number
                  }
                  ComputedFields: never
                  Insert: {
                    "last": number,"year": number
                  }
                  Update: {
                    "last"?: number,"year"?: number
                  }
                  Relationships: [
                    
                  ]
                },"login_attempts": {
                  Row: {
                    "attempted_at": string,"key": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attempted_at"?: string,"key": string
                  }
                  Update: {
                    "attempted_at"?: string,"key"?: string
                  }
                  Relationships: [
                    
                  ]
                },"paper_copies": {
                  Row: {
                    "booking_id": string,"code": string,"created_at": string,"id": string,"page_count": number,"paper_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id": string,"code": string,"created_at"?: string,"id"?: string,"page_count": number,"paper_id": string
                  }
                  Update: {
                    "booking_id"?: string,"code"?: string,"created_at"?: string,"id"?: string,"page_count"?: number,"paper_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_copies_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_copies_paper_id_fkey"
      columns: ["paper_id"]
isOneToOne: false
      referencedRelation: "exam_papers"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_downloads": {
                  Row: {
                    "at": string,"copy_id": string,"downloaded_by": string | null,"id": number,"kind": Database["public"]['Enums']["paper_download_kind"]
                  }
                  ComputedFields: never
                  Insert: {
                    "at"?: string,"copy_id": string,"downloaded_by"?: string | null,"id"?: never,"kind": Database["public"]['Enums']["paper_download_kind"]
                  }
                  Update: {
                    "at"?: string,"copy_id"?: string,"downloaded_by"?: string | null,"id"?: never,"kind"?: Database["public"]['Enums']["paper_download_kind"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_downloads_copy_id_fkey"
      columns: ["copy_id"]
isOneToOne: false
      referencedRelation: "paper_copies"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_downloads_downloaded_by_fkey"
      columns: ["downloaded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_hidden_areas": {
                  Row: {
                    "created_at": string,"created_by": string | null,"h": number,"id": string,"page": number,"paper_id": string,"w": number,"x": number,"y": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"h": number,"id"?: string,"page": number,"paper_id": string,"w": number,"x": number,"y": number
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"h"?: number,"id"?: string,"page"?: number,"paper_id"?: string,"w"?: number,"x"?: number,"y"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_hidden_areas_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_hidden_areas_paper_id_fkey"
      columns: ["paper_id"]
isOneToOne: false
      referencedRelation: "exam_papers"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_notices": {
                  Row: {
                    "created_at": string,"done_at": string | null,"exam_id": string,"failed_rounds": number,"id": number,"kind": string,"lease_until": string | null,"paper_ids": (string)[],"release_at": string | null,"retry_at": string | null,"window_until": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"done_at"?: string | null,"exam_id": string,"failed_rounds"?: number,"id"?: never,"kind": string,"lease_until"?: string | null,"paper_ids"?: (string)[],"release_at"?: string | null,"retry_at"?: string | null,"window_until": string
                  }
                  Update: {
                    "created_at"?: string,"done_at"?: string | null,"exam_id"?: string,"failed_rounds"?: number,"id"?: never,"kind"?: string,"lease_until"?: string | null,"paper_ids"?: (string)[],"release_at"?: string | null,"retry_at"?: string | null,"window_until"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_notices_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_notices_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_notices_sent": {
                  Row: {
                    "notice_id": number,"profile_id": string,"sent_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "notice_id": number,"profile_id": string,"sent_at"?: string
                  }
                  Update: {
                    "notice_id"?: number,"profile_id"?: string,"sent_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_notices_sent_notice_id_fkey"
      columns: ["notice_id"]
isOneToOne: false
      referencedRelation: "paper_notices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_notices_sent_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_page_roles": {
                  Row: {
                    "page": number,"paper_id": string,"role": Database["public"]['Enums']["page_role"]
                  }
                  ComputedFields: never
                  Insert: {
                    "page": number,"paper_id": string,"role": Database["public"]['Enums']["page_role"]
                  }
                  Update: {
                    "page"?: number,"paper_id"?: string,"role"?: Database["public"]['Enums']["page_role"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_page_roles_paper_id_fkey"
      columns: ["paper_id"]
isOneToOne: false
      referencedRelation: "exam_papers"
      referencedColumns: ["id"]
    }
                  ]
                },"parent_children": {
                  Row: {
                    "parent_id": string,"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "parent_id": string,"student_id": string
                  }
                  Update: {
                    "parent_id"?: string,"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "parent_children_parent_id_fkey"
      columns: ["parent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "parent_children_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"parent_link_blocks": {
                  Row: {
                    "created_at": string,"parent_id": string,"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"parent_id": string,"student_id": string
                  }
                  Update: {
                    "created_at"?: string,"parent_id"?: string,"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "parent_link_blocks_parent_id_fkey"
      columns: ["parent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "parent_link_blocks_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"parent_link_requests": {
                  Row: {
                    "created_at": string,"id": string,"parent_id": string,"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"parent_id": string,"student_id": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"parent_id"?: string,"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "parent_link_requests_parent_id_fkey"
      columns: ["parent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "parent_link_requests_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"pending_invites": {
                  Row: {
                    "created_at": string,"email": string,"invited_by": string | null,"role": Database["public"]['Enums']["app_role"],"token": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"email": string,"invited_by"?: string | null,"role": Database["public"]['Enums']["app_role"],"token"?: string
                  }
                  Update: {
                    "created_at"?: string,"email"?: string,"invited_by"?: string | null,"role"?: Database["public"]['Enums']["app_role"],"token"?: string
                  }
                  Relationships: [
                    
                  ]
                },"processing_jobs": {
                  Row: {
                    "attempts": number,"created_at": string,"finished_at": string | null,"id": number,"kind": string,"last_error": string | null,"locked_at": string | null,"locked_by": string | null,"run_after": string,"state": Database["public"]['Enums']["job_state"],"upload_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"created_at"?: string,"finished_at"?: string | null,"id"?: never,"kind": string,"last_error"?: string | null,"locked_at"?: string | null,"locked_by"?: string | null,"run_after"?: string,"state"?: Database["public"]['Enums']["job_state"],"upload_id": string
                  }
                  Update: {
                    "attempts"?: number,"created_at"?: string,"finished_at"?: string | null,"id"?: never,"kind"?: string,"last_error"?: string | null,"locked_at"?: string | null,"locked_by"?: string | null,"run_after"?: string,"state"?: Database["public"]['Enums']["job_state"],"upload_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "processing_jobs_upload_id_fkey"
      columns: ["upload_id"]
isOneToOne: false
      referencedRelation: "script_uploads"
      referencedColumns: ["id"]
    }
                  ]
                },"profiles": {
                  Row: {
                    "created_at": string,"email": string,"first_name": string,"id": string,"invite_sent_at": string | null,"last_name": string,"role": Database["public"]['Enums']["app_role"],"status": Database["public"]['Enums']["account_status"]
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"email": string,"first_name"?: string,"id": string,"invite_sent_at"?: string | null,"last_name"?: string,"role": Database["public"]['Enums']["app_role"],"status": Database["public"]['Enums']["account_status"]
                  }
                  Update: {
                    "created_at"?: string,"email"?: string,"first_name"?: string,"id"?: string,"invite_sent_at"?: string | null,"last_name"?: string,"role"?: Database["public"]['Enums']["app_role"],"status"?: Database["public"]['Enums']["account_status"]
                  }
                  Relationships: [
                    
                  ]
                },"scan_batches": {
                  Row: {
                    "centre_id": string,"created_at": string,"created_by": string | null,"exam_id": string,"id": string,"manifest_id": string | null,"number": string,"submitted_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "centre_id": string,"created_at"?: string,"created_by"?: string | null,"exam_id": string,"id"?: string,"manifest_id"?: string | null,"number": string,"submitted_at"?: string | null
                  }
                  Update: {
                    "centre_id"?: string,"created_at"?: string,"created_by"?: string | null,"exam_id"?: string,"id"?: string,"manifest_id"?: string | null,"number"?: string,"submitted_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "scan_batches_centre_id_fkey"
      columns: ["centre_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "scan_batches_manifest_id_fkey"
      columns: ["manifest_id"]
isOneToOne: false
      referencedRelation: "collection_manifests"
      referencedColumns: ["id"]
    }
                  ]
                },"script_exceptions": {
                  Row: {
                    "booking_id": string | null,"created_at": string,"details": NonNullable<Json>,"exam_id": string,"id": string,"kind": Database["public"]['Enums']["exception_kind"],"page_id": string | null,"reason": string | null,"resolution": string | null,"resolved_at": string | null,"resolved_by": string | null,"script_id": string | null,"state": string,"upload_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id"?: string | null,"created_at"?: string,"details"?: NonNullable<Json>,"exam_id": string,"id"?: string,"kind": Database["public"]['Enums']["exception_kind"],"page_id"?: string | null,"reason"?: string | null,"resolution"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"script_id"?: string | null,"state"?: string,"upload_id"?: string | null
                  }
                  Update: {
                    "booking_id"?: string | null,"created_at"?: string,"details"?: NonNullable<Json>,"exam_id"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["exception_kind"],"page_id"?: string | null,"reason"?: string | null,"resolution"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"script_id"?: string | null,"state"?: string,"upload_id"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"script_notices": {
                  Row: {
                    "attempts": number,"claimed_at": string | null,"created_at": string,"dedupe_key": string | null,"exam_id": string | null,"exception_id": string | null,"exception_kind": string | null,"group_id": string | null,"id": number,"kind": string,"script_id": string | null,"sent_at": string | null,"submission_id": string | null,"script_notice_content": Json | null,"script_notice_count": number | null,"script_notice_recipients": Json | null
                  }
                  ComputedFields: "script_notice_content" | "script_notice_count" | "script_notice_recipients"
                  Insert: {
                    "attempts"?: number,"claimed_at"?: string | null,"created_at"?: string,"dedupe_key"?: string | null,"exam_id"?: string | null,"exception_id"?: string | null,"exception_kind"?: string | null,"group_id"?: string | null,"id"?: never,"kind": string,"script_id"?: string | null,"sent_at"?: string | null,"submission_id"?: string | null
                  }
                  Update: {
                    "attempts"?: number,"claimed_at"?: string | null,"created_at"?: string,"dedupe_key"?: string | null,"exam_id"?: string | null,"exception_id"?: string | null,"exception_kind"?: string | null,"group_id"?: string | null,"id"?: never,"kind"?: string,"script_id"?: string | null,"sent_at"?: string | null,"submission_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_notices_exception_id_fkey"
      columns: ["exception_id"]
isOneToOne: false
      referencedRelation: "script_exceptions"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_notices_script_id_fkey"
      columns: ["script_id"]
isOneToOne: false
      referencedRelation: "scripts"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_notices_submission_id_fkey"
      columns: ["submission_id"]
isOneToOne: false
      referencedRelation: "home_submissions"
      referencedColumns: ["id"]
    }
                  ]
                },"script_notices_sent": {
                  Row: {
                    "notice_id": number,"profile_id": string,"sent_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "notice_id": number,"profile_id": string,"sent_at"?: string
                  }
                  Update: {
                    "notice_id"?: number,"profile_id"?: string,"sent_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_notices_sent_notice_id_fkey"
      columns: ["notice_id"]
isOneToOne: false
      referencedRelation: "script_notices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_notices_sent_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"script_page_hidden_areas": {
                  Row: {
                    "created_at": string,"created_by": string | null,"h": number,"id": string,"page_id": string,"w": number,"x": number,"y": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"h": number,"id"?: string,"page_id": string,"w": number,"x": number,"y": number
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"h"?: number,"id"?: string,"page_id"?: string,"w"?: number,"x"?: number,"y"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_page_hidden_areas_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_page_hidden_areas_page_id_fkey"
      columns: ["page_id"]
isOneToOne: false
      referencedRelation: "script_pages"
      referencedColumns: ["id"]
    }
                  ]
                },"script_page_links": {
                  Row: {
                    "copy_page": number,"page_id": string,"script_id": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "copy_page": number,"page_id": string,"script_id": string,"version": number
                  }
                  Update: {
                    "copy_page"?: number,"page_id"?: string,"script_id"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_page_links_page_id_fkey"
      columns: ["page_id"]
isOneToOne: false
      referencedRelation: "script_pages"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_page_links_script_id_fkey"
      columns: ["script_id"]
isOneToOne: false
      referencedRelation: "scripts"
      referencedColumns: ["id"]
    }
                  ]
                },"script_pages": {
                  Row: {
                    "blank": boolean,"booking_id": string | null,"copy_id": string | null,"copy_page": number | null,"created_at": string,"exam_id": string,"full_path": string,"full_rotation": number,"id": string,"marking_path": string | null,"placed_after": number | null,"quality": NonNullable<Json>,"replaced_at": string | null,"rotation": number,"source_index": number,"state": Database["public"]['Enums']["page_state"],"upload_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "blank"?: boolean,"booking_id"?: string | null,"copy_id"?: string | null,"copy_page"?: number | null,"created_at"?: string,"exam_id": string,"full_path": string,"full_rotation"?: number,"id"?: string,"marking_path"?: string | null,"placed_after"?: number | null,"quality"?: NonNullable<Json>,"replaced_at"?: string | null,"rotation"?: number,"source_index": number,"state": Database["public"]['Enums']["page_state"],"upload_id": string
                  }
                  Update: {
                    "blank"?: boolean,"booking_id"?: string | null,"copy_id"?: string | null,"copy_page"?: number | null,"created_at"?: string,"exam_id"?: string,"full_path"?: string,"full_rotation"?: number,"id"?: string,"marking_path"?: string | null,"placed_after"?: number | null,"quality"?: NonNullable<Json>,"replaced_at"?: string | null,"rotation"?: number,"source_index"?: number,"state"?: Database["public"]['Enums']["page_state"],"upload_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_pages_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_pages_copy_id_fkey"
      columns: ["copy_id"]
isOneToOne: false
      referencedRelation: "paper_copies"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_pages_upload_id_fkey"
      columns: ["upload_id"]
isOneToOne: false
      referencedRelation: "script_uploads"
      referencedColumns: ["id"]
    }
                  ]
                },"script_uploads": {
                  Row: {
                    "batch_id": string | null,"booking_id": string | null,"byte_size": number,"created_at": string,"discarded_at": string | null,"exam_id": string,"id": string,"kind": Database["public"]['Enums']["upload_kind"],"mime": string,"position": number | null,"purged_at": string | null,"sha256": string | null,"state": Database["public"]['Enums']["upload_state"],"storage_path": string,"stored_at": string | null,"submission_id": string | null,"uploaded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_id"?: string | null,"booking_id"?: string | null,"byte_size": number,"created_at"?: string,"discarded_at"?: string | null,"exam_id": string,"id"?: string,"kind": Database["public"]['Enums']["upload_kind"],"mime": string,"position"?: number | null,"purged_at"?: string | null,"sha256"?: string | null,"state"?: Database["public"]['Enums']["upload_state"],"storage_path": string,"stored_at"?: string | null,"submission_id"?: string | null,"uploaded_by": string
                  }
                  Update: {
                    "batch_id"?: string | null,"booking_id"?: string | null,"byte_size"?: number,"created_at"?: string,"discarded_at"?: string | null,"exam_id"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["upload_kind"],"mime"?: string,"position"?: number | null,"purged_at"?: string | null,"sha256"?: string | null,"state"?: Database["public"]['Enums']["upload_state"],"storage_path"?: string,"stored_at"?: string | null,"submission_id"?: string | null,"uploaded_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_uploads_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "scan_batches"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_uploads_submission_id_fkey"
      columns: ["submission_id"]
isOneToOne: false
      referencedRelation: "home_submissions"
      referencedColumns: ["id"]
    }
                  ]
                },"script_versions": {
                  Row: {
                    "created_at": string,"created_by": string | null,"reason": string | null,"script_id": string,"submission_id": string | null,"upload_id": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"reason"?: string | null,"script_id": string,"submission_id"?: string | null,"upload_id"?: string | null,"version": number
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"reason"?: string | null,"script_id"?: string,"submission_id"?: string | null,"upload_id"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_versions_script_id_fkey"
      columns: ["script_id"]
isOneToOne: false
      referencedRelation: "scripts"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_versions_submission_id_fkey"
      columns: ["submission_id"]
isOneToOne: false
      referencedRelation: "home_submissions"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_versions_upload_id_fkey"
      columns: ["upload_id"]
isOneToOne: false
      referencedRelation: "script_uploads"
      referencedColumns: ["id"]
    }
                  ]
                },"scripts": {
                  Row: {
                    "attention_notified_at": string | null,"booking_id": string,"complete": boolean,"created_at": string,"exam_id": string,"extras_locked": Json | null,"id": string,"late": boolean,"late_decision": string | null,"number": string,"received_at": string | null,"source": Database["public"]['Enums']["script_source"],"state": Database["public"]['Enums']["script_state"],"state_reason": string | null,"updated_at": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "attention_notified_at"?: string | null,"booking_id": string,"complete"?: boolean,"created_at"?: string,"exam_id": string,"extras_locked"?: Json | null,"id"?: string,"late"?: boolean,"late_decision"?: string | null,"number": string,"received_at"?: string | null,"source": Database["public"]['Enums']["script_source"],"state"?: Database["public"]['Enums']["script_state"],"state_reason"?: string | null,"updated_at"?: string,"version"?: number
                  }
                  Update: {
                    "attention_notified_at"?: string | null,"booking_id"?: string,"complete"?: boolean,"created_at"?: string,"exam_id"?: string,"extras_locked"?: Json | null,"id"?: string,"late"?: boolean,"late_decision"?: string | null,"number"?: string,"received_at"?: string | null,"source"?: Database["public"]['Enums']["script_source"],"state"?: Database["public"]['Enums']["script_state"],"state_reason"?: string | null,"updated_at"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "scripts_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: true
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "scripts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "scripts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"sitting_acknowledgements": {
                  Row: {
                    "acknowledged_by": string,"as_role": string,"at": string,"booking_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "acknowledged_by": string,"as_role": string,"at": string,"booking_id": string
                  }
                  Update: {
                    "acknowledged_by"?: string,"as_role"?: string,"at"?: string,"booking_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "sitting_acknowledgements_acknowledged_by_fkey"
      columns: ["acknowledged_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "sitting_acknowledgements_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: true
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    }
                  ]
                },"student_details": {
                  Row: {
                    "date_of_birth": string | null,"gender": string | null,"index_number": string | null,"parent_phone": string | null,"photo_path": string | null,"profile_id": string,"requested_by_parent": string | null,"school": string | null,"signup_parent_email": string | null,"signup_parent_name": string | null,"year_group": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "date_of_birth"?: string | null,"gender"?: string | null,"index_number"?: string | null,"parent_phone"?: string | null,"photo_path"?: string | null,"profile_id": string,"requested_by_parent"?: string | null,"school"?: string | null,"signup_parent_email"?: string | null,"signup_parent_name"?: string | null,"year_group"?: string | null
                  }
                  Update: {
                    "date_of_birth"?: string | null,"gender"?: string | null,"index_number"?: string | null,"parent_phone"?: string | null,"photo_path"?: string | null,"profile_id"?: string,"requested_by_parent"?: string | null,"school"?: string | null,"signup_parent_email"?: string | null,"signup_parent_name"?: string | null,"year_group"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "student_details_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: true
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "student_details_requested_by_parent_fkey"
      columns: ["requested_by_parent"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"student_subjects": {
                  Row: {
                    "student_id": string,"subject_id": number
                  }
                  ComputedFields: never
                  Insert: {
                    "student_id": string,"subject_id": number
                  }
                  Update: {
                    "student_id"?: string,"subject_id"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "student_subjects_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "student_subjects_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "subjects"
      referencedColumns: ["id"]
    }
                  ]
                },"subjects": {
                  Row: {
                    "active": boolean,"id": number,"kind": Database["public"]['Enums']["subject_kind"],"name": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"id"?: never,"kind": Database["public"]['Enums']["subject_kind"],"name": string
                  }
                  Update: {
                    "active"?: boolean,"id"?: never,"kind"?: Database["public"]['Enums']["subject_kind"],"name"?: string
                  }
                  Relationships: [
                    
                  ]
                },"teacher_subjects": {
                  Row: {
                    "subject_id": number,"teacher_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "subject_id": number,"teacher_id": string
                  }
                  Update: {
                    "subject_id"?: number,"teacher_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "teacher_subjects_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "subjects"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "teacher_subjects_teacher_id_fkey"
      columns: ["teacher_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"tutor_students": {
                  Row: {
                    "student_id": string,"tutor_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "student_id": string,"tutor_id": string
                  }
                  Update: {
                    "student_id"?: string,"tutor_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "tutor_students_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tutor_students_tutor_id_fkey"
      columns: ["tutor_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"venues": {
                  Row: {
                    "active": boolean,"created_at": string,"id": string,"name": string,"rooms": (string)[]
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"created_at"?: string,"id"?: string,"name": string,"rooms"?: (string)[]
                  }
                  Update: {
                    "active"?: boolean,"created_at"?: string,"id"?: string,"name"?: string,"rooms"?: (string)[]
                  }
                  Relationships: [
                    
                  ]
                }
          }
          Views: {
            "exams_public": {
                  Row: {
                    "booking_deadline": string,"centres": Json | null,"duration_minutes": number,"format": Database["public"]['Enums']["exam_format"],"id": string,"paper": string,"price_pence": number,"seats_left": number | null,"starts_at": string,"subject": string,"title": string
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                }
          }
          Functions: {
            "admin_add_booking":
{ Args: { "p_centre"?: string,"p_exam": string,"p_note": string,"p_paid": boolean,"p_sitting"?: Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"approve_student_tx":
{ Args: { "p_actor": string,"p_student": string,"p_year"?: number }; Returns: {
              "index_number": string,"invite_token": string,"parent_email": string,"parent_id": string
            }[]
                           },
"attendance_can_manage":
{ Args: { "p_actor": string,"p_subject": number }; Returns: boolean
                           },
"attendance_lookup":
{ Args: { "p_centre": string,"p_index": string }; Returns: Json
                           },
"attendance_lookup_as":
{ Args: { "p_actor": string,"p_centre": string,"p_index": string }; Returns: Json
                           },
"booking_create_as":
{ Args: { "p_actor": string,"p_centre"?: string,"p_exam": string,"p_now": string,"p_sitting"?: Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"booking_create_core":
{ Args: { "p_by": string,"p_centre": string,"p_enforce_deadline": boolean,"p_exam": string,"p_note": string,"p_now": string,"p_paid": boolean,"p_sitting": Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"booking_paper_state":
{ Args: { "p_booking": string,"p_now"?: string }; Returns: Json
                           },
"booking_sitting_state":
{ Args: { "p_booking": string,"p_now"?: string }; Returns: Json
                           },
"can_manage_account":
{ Args: { "p_action": string,"p_actor": string,"p_target": string }; Returns: string
                           },
"can_reject_student":
{ Args: { "p_student": string }; Returns: string
                           },
"cancel_booking_admin":
{ Args: { "p_booking": string,"p_note": string }; Returns: Json
                           },
"centre_seats_taken":
{ Args: { "p_centre": string }; Returns: number
                           },
"change_booking_sitting":
{ Args: { "p_booking": string,"p_centre": string,"p_reason": string,"p_sitting": Database["public"]['Enums']["sitting_mode"] }; Returns: Json
                           },
"claim_invite":
{ Args: { "p_email": string,"p_role": Database["public"]['Enums']["app_role"],"p_token": string,"p_user": string }; Returns: string
                           },
"clear_invite_tx":
{ Args: { "p_actor": string,"p_email": string }; Returns: string
                           },
"close_register":
{ Args: { "p_centre": string }; Returns: Json
                           },
"close_register_as":
{ Args: { "p_actor": string,"p_centre": string,"p_now": string }; Returns: Json
                           },
"collection_list":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"collection_manifest_create":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"collection_record":
{ Args: { "p_booking": string,"p_extra_sheets": number }; Returns: Json
                           },
"complete_finished_exams":
{ Args: { "p_now"?: string }; Returns: number
                           },
"complete_profile":
{ Args: { "p_gender": string,"p_parent_phone": string,"p_photo_path"?: string,"p_subject_ids": (number)[],"p_year_group": string }; Returns: undefined
                           },
"copy_code_new":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"copy_code_valid":
{ Args: { "p_code": string }; Returns: boolean
                           },
"create_booking":
{ Args: { "p_centre"?: string,"p_exam": string,"p_sitting"?: Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"custody_list":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"custody_record":
{ Args: { "p_centre": string,"p_exam": string,"p_from": string,"p_location": string,"p_manifest"?: string,"p_note": string,"p_step": string,"p_to": string }; Returns: Json
                           },
"custody_staff":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"decide_cancellation":
{ Args: { "p_approve": boolean,"p_booking": string,"p_note": string,"p_refund_pence": number }; Returns: Json
                           },
"decide_parent_link_tx":
{ Args: { "p_actor": string,"p_approve": boolean,"p_request": string }; Returns: string
                           },
"delete_account_tx":
{ Args: { "p_actor": string,"p_target": string }; Returns: string
                           },
"delete_own_account_tx":
{ Args: { "p_user": string }; Returns: string
                           },
"edit_parent_email_tx":
{ Args: { "p_actor": string,"p_email": string,"p_target": string }; Returns: string
                           },
"exam_code_base":
{ Args: { "p_paper": string,"p_starts_at": string,"p_subject": number }; Returns: string
                           },
"exam_code_generate":
{ Args: { "p_paper": string,"p_self": string,"p_starts_at": string,"p_subject": number }; Returns: string
                           },
"expire_unconfirmed":
{ Args: { "p_now"?: string }; Returns: number
                           },
"expire_unpaid_bookings":
{ Args: { "p_now"?: string }; Returns: number
                           },
"family_has_booking":
{ Args: { "p_exam": string }; Returns: boolean
                           },
"home_booking_lock":
{ Args: { "p_booking": string }; Returns: undefined
                           },
"home_drafts_stored":
{ Args: { "p_now": string }; Returns: {
              "booking_id": string,"exam_id": string,"files": number,"last_file_at": string,"late": boolean,"submission_id": string
            }[]
                           },
"home_drafts_unsubmitted":
{ Args: { "p_exam"?: string,"p_now"?: string }; Returns: Json
                           },
"home_missing_confirm_blank":
{ Args: { "p_pages": (number)[],"p_submission": string }; Returns: Json
                           },
"home_missing_pages":
{ Args: { "p_skip_confirmed": boolean,"p_submission": string }; Returns: (number)[]
                           },
"home_page_place":
{ Args: { "p_after_page": number,"p_page": string }; Returns: Json
                           },
"home_page_send_as_is":
{ Args: { "p_page": string }; Returns: Json
                           },
"home_reevaluate":
{ Args: { "p_booking": string,"p_submission": string }; Returns: Database["public"]['Enums']["submission_state"]
                           },
"home_submission_accept_draft":
{ Args: { "p_now"?: string,"p_reason": string,"p_submission": string }; Returns: Json
                           },
"home_submission_assemble":
{ Args: { "p_now": string,"p_submission": string,"p_upload": string }; Returns: boolean
                           },
"home_submission_evaluate":
{ Args: { "p_now": string,"p_submission": string }; Returns: Database["public"]['Enums']["submission_state"]
                           },
"home_submission_latest":
{ Args: { "p_booking": string }; Returns: {
              "blank_confirmed": (number)[],
"booking_id": string,
"checked_at": string | null,
"id": string,
"late": boolean,
"rejected_reason": string | null,
"replaces_all": boolean,
"seq": number,
"state": Database["public"]['Enums']["submission_state"],
"submitted_at": string | null,
"submitted_by": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "home_submissions"
        isOneToOne: true
        isSetofReturn: false
      } },
"home_submission_open":
{ Args: { "p_booking": string,"p_now"?: string,"p_replaces_all"?: boolean }; Returns: Json
                           },
"home_submission_result":
{ Args: { "p_submission": string }; Returns: Json
                           },
"home_submission_send":
{ Args: { "p_actor": string,"p_now": string,"p_submission": string }; Returns: undefined
                           },
"home_submission_status":
{ Args: { "p_booking": string }; Returns: Json
                           },
"home_submission_submit":
{ Args: { "p_now"?: string,"p_submission": string }; Returns: Json
                           },
"home_upload_code":
{ Args: { "p_actor": string,"p_at": string,"p_booking": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']> }; Returns: string
                           },
"home_upload_max_bytes":
{ Args: { "p_kind": Database["public"]['Enums']["upload_kind"] }; Returns: number
                           },
"home_upload_type_ok":
{ Args: { "p_kind": Database["public"]['Enums']["upload_kind"],"p_mime": string }; Returns: boolean
                           },
"is_staff_admin":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"link_children_to_parent":
{ Args: { "p_parent": string }; Returns: number
                           },
"link_student_to_parent":
{ Args: { "p_parent": string,"p_student": string }; Returns: string
                           },
"login_attempt_begin":
{ Args: { "p_idx_key": string,"p_ip_key": string }; Returns: boolean
                           },
"login_attempt_begin_n":
{ Args: { "p_key_a": string,"p_key_b": string,"p_limit_a": number,"p_limit_b": number }; Returns: boolean
                           },
"login_attempt_refund":
{ Args: { "p_idx_key": string,"p_ip_key": string }; Returns: undefined
                           },
"login_attempt_refund_key":
{ Args: { "p_key": string }; Returns: undefined
                           },
"login_attempt_succeed":
{ Args: { "p_idx_key": string,"p_ip_key": string }; Returns: undefined
                           },
"mark_attendance":
{ Args: { "p_centre": string,"p_student": string }; Returns: Json
                           },
"mark_attendance_as":
{ Args: { "p_actor": string,"p_centre": string,"p_now": string,"p_student": string }; Returns: Json
                           },
"mark_booking_paid":
{ Args: { "p_booking": string,"p_note": string }; Returns: Json
                           },
"money_totals":
{ Args: { "p_from": string,"p_to": string }; Returns: Json
                           },
"my_role":
{ Args: Record<PropertyKey, never>; Returns: Database["public"]['Enums']["app_role"]
                           },
"my_status":
{ Args: Record<PropertyKey, never>; Returns: Database["public"]['Enums']["account_status"]
                           },
"normalise_index":
{ Args: { "p_raw": string }; Returns: string
                           },
"paper_access_code":
{ Args: { "p_actor": string,"p_booking": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_exam": Omit<Database["public"]['Tables']["exams"]['Row'], Database["public"]['Tables']["exams"]['ComputedFields']>,"p_kind": Database["public"]['Enums']["paper_download_kind"],"p_now": string }; Returns: string
                           },
"paper_clock":
{ Args: { "p_now": string }; Returns: string
                           },
"paper_copy_issue":
{ Args: { "p_booking": string,"p_kind": Database["public"]['Enums']["paper_download_kind"],"p_now"?: string }; Returns: Json
                           },
"paper_corrected_due":
{ Args: { "p_now"?: string }; Returns: {
              "exam_id": string,"paper": string,"paper_ids": (string)[],"title": string
            }[]
                           },
"paper_corrected_recipients":
{ Args: { "p_paper_ids": (string)[] }; Returns: {
              "email": string,"first_name": string,"profile_id": string
            }[]
                           },
"paper_download_log":
{ Args: { "p_copy": string,"p_kind": Database["public"]['Enums']["paper_download_kind"] }; Returns: Json
                           },
"paper_exam_title":
{ Args: { "p_paper": string,"p_title": string }; Returns: string
                           },
"paper_hold":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"paper_home_downloads_last_hour":
{ Args: { "p_booking": string,"p_now": string }; Returns: number
                           },
"paper_insert_issue":
{ Args: { "p_booking": string,"p_insert": string,"p_now"?: string }; Returns: Json
                           },
"paper_lookup_codes":
{ Args: { "p_items": Json }; Returns: Json
                           },
"paper_notice_finish":
{ Args: { "p_failed": number,"p_notice": number,"p_now"?: string,"p_sent": number }; Returns: string
                           },
"paper_notice_mark":
{ Args: { "p_notice": number,"p_now"?: string,"p_profile": string }; Returns: string
                           },
"paper_notice_next":
{ Args: { "p_exclude"?: (number)[],"p_now"?: string }; Returns: {
              "exam_id": string,"kind": string,"notice_id": number,"paper": string,"title": string
            }[]
                           },
"paper_notice_open":
{ Args: { "p_now"?: string }; Returns: number
                           },
"paper_notice_recipients":
{ Args: { "p_notice": number }; Returns: {
              "email": string,"first_name": string,"profile_id": string
            }[]
                           },
"paper_notice_unmark":
{ Args: { "p_notice": number,"p_profile": string }; Returns: undefined
                           },
"paper_page_layout":
{ Args: { "p_paper": string }; Returns: Json
                           },
"paper_release_at":
{ Args: { "p_exam": string }; Returns: string
                           },
"paper_release_due":
{ Args: { "p_now"?: string }; Returns: {
              "exam_id": string,"paper": string,"title": string
            }[]
                           },
"paper_release_notify_tick":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"paper_release_now":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"paper_release_recipients":
{ Args: { "p_exam": string }; Returns: {
              "email": string,"first_name": string,"profile_id": string
            }[]
                           },
"paper_resume":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"paper_window_code":
{ Args: { "p_exam": Omit<Database["public"]['Tables']["exams"]['Row'], Database["public"]['Tables']["exams"]['ComputedFields']>,"p_now": string }; Returns: string
                           },
"processing_job_claim":
{ Args: { "p_now"?: string,"p_worker": string }; Returns: Json
                           },
"processing_job_fail":
{ Args: { "p_error": string,"p_job": Omit<Database["public"]['Tables']["processing_jobs"]['Row'], Database["public"]['Tables']["processing_jobs"]['ComputedFields']>,"p_now": string }; Returns: undefined
                           },
"processing_job_finish":
{ Args: { "p_attempt": number,"p_error"?: string,"p_job": number,"p_now"?: string,"p_ok": boolean,"p_worker": string }; Returns: Json
                           },
"processing_job_heartbeat":
{ Args: { "p_attempt": number,"p_job": number,"p_now"?: string,"p_worker": string }; Returns: boolean
                           },
"purge_student_residue":
{ Args: { "p_user": string }; Returns: undefined
                           },
"register_child_tx":
{ Args: { "p_child": string,"p_parent": string }; Returns: boolean
                           },
"register_exam_paper":
{ Args: { "p_byte_size": number,"p_exam": string,"p_kind": Database["public"]['Enums']["paper_kind"],"p_page_count": number,"p_reason": string,"p_storage_path": string,"p_title": string }; Returns: Json
                           },
"reject_student_tx":
{ Args: { "p_actor": string,"p_student": string }; Returns: string
                           },
"remove_exam_insert":
{ Args: { "p_paper": string,"p_reason": string }; Returns: Json
                           },
"remove_staff_tx":
{ Args: { "p_actor": string,"p_target": string }; Returns: string
                           },
"replace_unconfirmed_signup":
{ Args: { "p_email": string }; Returns: string
                           },
"request_cancellation":
{ Args: { "p_booking": string }; Returns: Json
                           },
"request_cancellation_as":
{ Args: { "p_actor": string,"p_booking": string,"p_now": string }; Returns: Json
                           },
"request_parent_link_tx":
{ Args: { "p_dob": string,"p_index": string,"p_parent": string }; Returns: boolean
                           },
"save_exam":
{ Args: { "p_booking_deadline": string,"p_centres": Json,"p_duration_minutes": number,"p_format": Database["public"]['Enums']["exam_format"],"p_id": string,"p_paper": string,"p_price_pence": number,"p_starts_at": string,"p_subject_id": number,"p_title": string }; Returns: Json
                           },
"save_venue":
{ Args: { "p_active": boolean,"p_id": string,"p_name": string,"p_rooms": (string)[] }; Returns: Json
                           },
"scan_batch_create":
{ Args: { "p_centre": string,"p_exam": string,"p_manifest_number"?: string }; Returns: Json
                           },
"scan_batch_status":
{ Args: { "p_batch": string }; Returns: Json
                           },
"scan_batch_submit":
{ Args: { "p_batch": string }; Returns: Json
                           },
"scan_booking_complete":
{ Args: { "p_booking": string }; Returns: Json
                           },
"scan_centre_complete":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"scan_upload_begin":
{ Args: { "p_batch": string,"p_bytes": number,"p_mime": string }; Returns: Json
                           },
"scan_upload_max_bytes":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"scan_upload_type_ok":
{ Args: { "p_mime": string }; Returns: boolean
                           },
"script_booking_json":
{ Args: { "p_booking": string }; Returns: Json
                           },
"script_booking_locked":
{ Args: { "p_booking": string }; Returns: boolean
                           },
"script_bookings_lock":
{ Args: { "p_bookings": (string)[] }; Returns: undefined
                           },
"script_centre_checked":
{ Args: { "p_booking": string }; Returns: boolean
                           },
"script_create":
{ Args: { "p_booking": string,"p_now": string,"p_source": Database["public"]['Enums']["script_source"] }; Returns: {
              "attention_notified_at": string | null,
"booking_id": string,
"complete": boolean,
"created_at": string,
"exam_id": string,
"extras_locked": Json | null,
"id": string,
"late": boolean,
"late_decision": string | null,
"number": string,
"received_at": string | null,
"source": Database["public"]['Enums']["script_source"],
"state": Database["public"]['Enums']["script_state"],
"state_reason": string | null,
"updated_at": string,
"version": number
            }
                          SetofOptions: {
        from: "*"
        to: "scripts"
        isOneToOne: true
        isSetofReturn: false
      } },
"script_detail":
{ Args: { "p_script": string }; Returns: Json
                           },
"script_discarded_take":
{ Args: { "p_limit": number,"p_now"?: string }; Returns: Json
                           },
"script_evaluate":
{ Args: { "p_script": string }; Returns: undefined
                           },
"script_evaluate_at":
{ Args: { "p_now": string,"p_script": string }; Returns: undefined
                           },
"script_exception_assign":
{ Args: { "p_booking": string,"p_copy_page": number,"p_exception": string,"p_no_name"?: boolean,"p_reason": string,"p_replace"?: boolean }; Returns: Json
                           },
"script_exception_blank":
{ Args: { "p_exception": string,"p_reason": string }; Returns: Json
                           },
"script_exception_candidates":
{ Args: { "p_exam": string,"p_query": string }; Returns: Json
                           },
"script_exception_close":
{ Args: { "p_action": string,"p_actor": string,"p_id": string,"p_now": string,"p_reason": string,"p_resolution": string }; Returns: undefined
                           },
"script_exception_confirm":
{ Args: { "p_exception": string,"p_no_name"?: boolean,"p_reason"?: string }; Returns: Json
                           },
"script_exception_conflict":
{ Args: { "p_exception": string }; Returns: Json
                           },
"script_exception_dismiss_missing":
{ Args: { "p_exception": string,"p_pages": (number)[],"p_reason": string }; Returns: Json
                           },
"script_exception_json":
{ Args: { "p_exception": string }; Returns: Json
                           },
"script_exception_keep_existing":
{ Args: { "p_exception": string,"p_reason": string }; Returns: Json
                           },
"script_exception_reject":
{ Args: { "p_exception": string,"p_reason": string }; Returns: Json
                           },
"script_exception_seq":
{ Args: { "p_exception": string }; Returns: number
                           },
"script_exceptions_list":
{ Args: { "p_exam"?: string,"p_kind"?: Database["public"]['Enums']["exception_kind"],"p_state"?: string }; Returns: Json
                           },
"script_extra_pages":
{ Args: { "p_script": string }; Returns: {
              "file_position": number,"page_id": string,"placed_after": number,"source_index": number
            }[]
                           },
"script_home_reject":
{ Args: { "p_actor": string,"p_booking": string,"p_now": string,"p_reason": string,"p_subs": (string)[] }; Returns: undefined
                           },
"script_late_decide":
{ Args: { "p_accept": boolean,"p_reason": string,"p_script": string }; Returns: Json
                           },
"script_links":
{ Args: { "p_script": string }; Returns: Json
                           },
"script_links_current":
{ Args: { "p_links": Json,"p_script": string }; Returns: Json
                           },
"script_links_write":
{ Args: { "p_actor": string,"p_links": Json,"p_now": string,"p_reason": string,"p_script": string }; Returns: boolean
                           },
"script_notice_content":
{ Args: { "p_notice": Omit<Database["public"]['Tables']["script_notices"]['Row'], Database["public"]['Tables']["script_notices"]['ComputedFields']> }; Returns: Json
                           },
"script_notice_count":
{ Args: { "p_notice": Omit<Database["public"]['Tables']["script_notices"]['Row'], Database["public"]['Tables']["script_notices"]['ComputedFields']> }; Returns: number
                           },
"script_notice_given_up":
{ Args: { "p_now"?: string }; Returns: number
                           },
"script_notice_mark":
{ Args: { "p_id": number,"p_now"?: string,"p_ok": boolean }; Returns: undefined
                           },
"script_notice_next":
{ Args: { "p_limit": number,"p_now"?: string }; Returns: Json
                           },
"script_notice_recipients":
{ Args: { "p_notice": Omit<Database["public"]['Tables']["script_notices"]['Row'], Database["public"]['Tables']["script_notices"]['ComputedFields']> }; Returns: Json
                           },
"script_notice_record":
{ Args: { "p_id": number,"p_profile": string }; Returns: string
                           },
"script_notice_unmark":
{ Args: { "p_id": number,"p_profile": string }; Returns: undefined
                           },
"script_notify_tick":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"script_number_next":
{ Args: { "p_exam": string }; Returns: string
                           },
"script_page_areas_key":
{ Args: { "p_page": string }; Returns: string
                           },
"script_page_binding":
{ Args: { "p_page": string }; Returns: Json
                           },
"script_page_bookings":
{ Args: { "p_page": string }; Returns: (string)[]
                           },
"script_page_confirm_given":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_confirmed":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_copy":
{ Args: { "p_page": string }; Returns: Record<string, unknown>
                           },
"script_page_elsewhere":
{ Args: { "p_page": string,"p_script": string }; Returns: string
                           },
"script_page_is_answer":
{ Args: { "p_copy": string,"p_page": number }; Returns: boolean
                           },
"script_page_json":
{ Args: { "p_page": string }; Returns: Json
                           },
"script_page_lock":
{ Args: { "p_extra": (string)[],"p_page": string }; Returns: (string)[]
                           },
"script_page_locked":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_marking_lost":
{ Args: { "p_cleared"?: boolean,"p_extra"?: Json,"p_page": string }; Returns: undefined
                           },
"script_page_marking_made":
{ Args: { "p_page": string }; Returns: undefined
                           },
"script_page_owners":
{ Args: { "p_page": string }; Returns: (string)[]
                           },
"script_page_poor":
{ Args: { "p_answer": boolean,"p_marking": string,"p_quality": Json }; Returns: boolean
                           },
"script_page_refused":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_remask":
{ Args: { "p_page": string }; Returns: undefined
                           },
"script_page_remask_context":
{ Args: { "p_page": string }; Returns: Json
                           },
"script_page_remask_key":
{ Args: { "p_page": string }; Returns: string
                           },
"script_page_remove":
{ Args: { "p_copy_page": number,"p_reason": string,"p_script": string }; Returns: Json
                           },
"script_page_rotate":
{ Args: { "p_page": string,"p_quarter_turns": number,"p_reason": string }; Returns: Json
                           },
"script_page_set_aside":
{ Args: { "p_actor": string,"p_now": string,"p_page": string,"p_reason": string }; Returns: undefined
                           },
"script_page_set_hidden_areas":
{ Args: { "p_areas": Json,"p_page": string,"p_reason": string }; Returns: Json
                           },
"script_page_slot_answer":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_staff_work":
{ Args: { "p_page": string }; Returns: string
                           },
"script_pages_elsewhere":
{ Args: { "p_pages": (string)[],"p_script": string }; Returns: (string)[]
                           },
"script_pages_record":
{ Args: { "p_attempt": number,"p_job": number,"p_now"?: string,"p_pages": Json,"p_sha256": string,"p_worker": string }; Returns: Json
                           },
"script_pages_remasked":
{ Args: { "p_attempt": number,"p_job": number,"p_now"?: string,"p_pages": Json,"p_worker": string }; Returns: Json
                           },
"script_pages_valid":
{ Args: { "p_pages": Json,"p_prefix": string }; Returns: boolean
                           },
"script_raise_mixed":
{ Args: { "p_script": string,"p_upload": string }; Returns: undefined
                           },
"script_reject_targets":
{ Args: { "p_exception": string }; Returns: (string)[]
                           },
"script_remask_queue":
{ Args: { "p_upload": string }; Returns: boolean
                           },
"script_resolution_lock":
{ Args: { "p_exception": string,"p_extra": (string)[] }; Returns: (string)[]
                           },
"script_resolution_reason":
{ Args: { "p_reason": string }; Returns: string
                           },
"script_resolution_settle":
{ Args: { "p_actor": string,"p_booking": string,"p_reason": string }; Returns: undefined
                           },
"script_shared_links":
{ Args: { "p_script": string }; Returns: number
                           },
"script_slot_copy":
{ Args: { "p_script": string }; Returns: string
                           },
"script_slot_staff_placed":
{ Args: { "p_copy_page": number,"p_page": string,"p_script": string }; Returns: boolean
                           },
"script_slots_dropped":
{ Args: { "p_links": Json,"p_script": string,"p_upload": string,"p_written": Json }; Returns: undefined
                           },
"script_stale_links":
{ Args: { "p_script": string }; Returns: number
                           },
"script_stats_refresh":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"script_upload_begin":
{ Args: { "p_bytes": number,"p_kind": Database["public"]['Enums']["upload_kind"],"p_mime": string,"p_now"?: string,"p_submission": string }; Returns: Json
                           },
"script_upload_bookings":
{ Args: { "p_upload": string }; Returns: (string)[]
                           },
"script_upload_discard":
{ Args: { "p_upload": string }; Returns: Json
                           },
"script_upload_lock":
{ Args: { "p_upload": string }; Returns: (string)[]
                           },
"script_upload_never_handed_in":
{ Args: { "p_now": string,"p_upload": string }; Returns: boolean
                           },
"script_upload_path_allowed":
{ Args: { "p_add": boolean,"p_path": string }; Returns: boolean
                           },
"script_upload_processed":
{ Args: { "p_now": string,"p_upload": string }; Returns: undefined
                           },
"script_upload_purged":
{ Args: { "p_ids": (string)[],"p_now"?: string }; Returns: undefined
                           },
"script_upload_reorder":
{ Args: { "p_submission": string,"p_uploads": (string)[] }; Returns: Json
                           },
"script_upload_reprocess":
{ Args: { "p_reason": string,"p_upload": string }; Returns: Json
                           },
"script_upload_reprocess_refused":
{ Args: { "p_upload": string }; Returns: string
                           },
"script_upload_staff_changes":
{ Args: { "p_placed"?: boolean,"p_upload": string }; Returns: string
                           },
"script_upload_stale_links":
{ Args: { "p_upload": string }; Returns: number
                           },
"script_upload_stored":
{ Args: { "p_upload": string }; Returns: Json
                           },
"script_version_write":
{ Args: { "p_links": Json,"p_now": string,"p_reason": string,"p_script": string,"p_submission": string,"p_upload": string }; Returns: boolean
                           },
"script_void":
{ Args: { "p_reason": string,"p_script": string }; Returns: Json
                           },
"scripts_dashboard":
{ Args: { "p_now"?: string }; Returns: Json
                           },
"scripts_list":
{ Args: { "p_exam"?: string,"p_late"?: boolean,"p_source"?: Database["public"]['Enums']["script_source"],"p_state"?: Database["public"]['Enums']["script_state"] }; Returns: Json
                           },
"set_account_status_tx":
{ Args: { "p_action": string,"p_actor": string,"p_target": string }; Returns: string
                           },
"set_exam_home_rules":
{ Args: { "p_exam": string,"p_materials": string,"p_rules": string }; Returns: Json
                           },
"set_exam_paper_settings":
{ Args: { "p_exam": string,"p_exam_code": string,"p_reason"?: string,"p_release_minutes_before": number,"p_spare_pages": number }; Returns: Json
                           },
"set_exam_status":
{ Args: { "p_id": string,"p_status": Database["public"]['Enums']["exam_status"] }; Returns: Json
                           },
"set_paper_hidden_areas":
{ Args: { "p_areas": Json,"p_paper": string }; Returns: Json
                           },
"set_paper_page_roles":
{ Args: { "p_paper": string,"p_roles": Json }; Returns: Json
                           },
"sitting_access_code":
{ Args: { "p_acting": boolean,"p_actor": string,"p_booking": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']> }; Returns: string
                           },
"sitting_acknowledge":
{ Args: { "p_booking": string,"p_now"?: string }; Returns: Json
                           },
"sitting_phase":
{ Args: { "p_exam": Omit<Database["public"]['Tables']["exams"]['Row'], Database["public"]['Tables']["exams"]['ComputedFields']>,"p_now": string }; Returns: string
                           }
          }
          Enums: {
            "account_status": "unconfirmed"|"pending"|"profile_incomplete"|"active"|"suspended","app_role": "owner"|"admin"|"teacher"|"tutor"|"corrector"|"student"|"parent","attendance_status": "present"|"late"|"absent","booking_status": "awaiting_payment"|"paid"|"cancel_requested"|"refunded"|"part_refunded"|"cancelled"|"expired","exam_format": "in_person"|"online"|"both","exam_status": "draft"|"published"|"cancelled"|"completed","exception_kind": "no_code"|"unknown_code"|"other_exam"|"not_expected"|"duplicate"|"missing_pages"|"uncoded_family_page"|"mixed_versions"|"poor_quality"|"late"|"name_visible"|"processing_failed","job_state": "queued"|"running"|"done"|"failed","page_role": "answer"|"cover"|"blank"|"information","page_state": "matched"|"blank"|"duplicate"|"unmatched"|"rejected","paper_download_kind": "home"|"print_pack"|"reprint"|"admin_preview","paper_kind": "paper"|"insert","script_source": "home"|"centre","script_state": "receiving"|"checking"|"needs_attention"|"verified"|"ready_to_mark"|"marking"|"marked"|"checked"|"final"|"withdrawn"|"void","sitting_mode": "centre"|"home","subject_kind": "school"|"entrance","submission_state": "draft"|"checking"|"received"|"needs_attention"|"rejected","upload_kind": "home_photo"|"home_pdf"|"scan_file","upload_state": "pending"|"stored"|"discarded"|"queued"|"processing"|"processed"|"failed"
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            "account_status": ["unconfirmed", "pending", "profile_incomplete", "active", "suspended"],"app_role": ["owner", "admin", "teacher", "tutor", "corrector", "student", "parent"],"attendance_status": ["present", "late", "absent"],"booking_status": ["awaiting_payment", "paid", "cancel_requested", "refunded", "part_refunded", "cancelled", "expired"],"exam_format": ["in_person", "online", "both"],"exam_status": ["draft", "published", "cancelled", "completed"],"exception_kind": ["no_code", "unknown_code", "other_exam", "not_expected", "duplicate", "missing_pages", "uncoded_family_page", "mixed_versions", "poor_quality", "late", "name_visible", "processing_failed"],"job_state": ["queued", "running", "done", "failed"],"page_role": ["answer", "cover", "blank", "information"],"page_state": ["matched", "blank", "duplicate", "unmatched", "rejected"],"paper_download_kind": ["home", "print_pack", "reprint", "admin_preview"],"paper_kind": ["paper", "insert"],"script_source": ["home", "centre"],"script_state": ["receiving", "checking", "needs_attention", "verified", "ready_to_mark", "marking", "marked", "checked", "final", "withdrawn", "void"],"sitting_mode": ["centre", "home"],"subject_kind": ["school", "entrance"],"submission_state": ["draft", "checking", "received", "needs_attention", "rejected"],"upload_kind": ["home_photo", "home_pdf", "scan_file"],"upload_state": ["pending", "stored", "discarded", "queued", "processing", "processed", "failed"]
          }
        }
} as const
