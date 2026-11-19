
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
                    "byte_size": number,"corrected_notified_at": string | null,"exam_id": string,"id": string,"kind": Database["public"]['Enums']["paper_kind"],"page_count": number,"replace_reason": string | null,"storage_path": string,"superseded_at": string | null,"title": string,"uploaded_at": string,"uploaded_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "byte_size": number,"corrected_notified_at"?: string | null,"exam_id": string,"id"?: string,"kind": Database["public"]['Enums']["paper_kind"],"page_count": number,"replace_reason"?: string | null,"storage_path": string,"superseded_at"?: string | null,"title": string,"uploaded_at"?: string,"uploaded_by"?: string | null,"version": number
                  }
                  Update: {
                    "byte_size"?: number,"corrected_notified_at"?: string | null,"exam_id"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["paper_kind"],"page_count"?: number,"replace_reason"?: string | null,"storage_path"?: string,"superseded_at"?: string | null,"title"?: string,"uploaded_at"?: string,"uploaded_by"?: string | null,"version"?: number
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
                    "booking_deadline": string,"created_at": string,"created_by": string | null,"currency": string,"duration_minutes": number,"exam_code": string,"format": Database["public"]['Enums']["exam_format"],"id": string,"paper": string,"price_confirmed": boolean,"price_pence": number,"release_held": boolean,"release_minutes_before": number,"release_notified_at": string | null,"released_early_at": string | null,"spare_pages": number,"starts_at": string,"status": Database["public"]['Enums']["exam_status"],"subject_id": number,"title": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_deadline": string,"created_at"?: string,"created_by"?: string | null,"currency"?: string,"duration_minutes": number,"exam_code": string,"format": Database["public"]['Enums']["exam_format"],"id"?: string,"paper": string,"price_confirmed"?: boolean,"price_pence": number,"release_held"?: boolean,"release_minutes_before"?: number,"release_notified_at"?: string | null,"released_early_at"?: string | null,"spare_pages"?: number,"starts_at": string,"status"?: Database["public"]['Enums']["exam_status"],"subject_id": number,"title": string,"updated_at"?: string
                  }
                  Update: {
                    "booking_deadline"?: string,"created_at"?: string,"created_by"?: string | null,"currency"?: string,"duration_minutes"?: number,"exam_code"?: string,"format"?: Database["public"]['Enums']["exam_format"],"id"?: string,"paper"?: string,"price_confirmed"?: boolean,"price_pence"?: number,"release_held"?: boolean,"release_minutes_before"?: number,"release_notified_at"?: string | null,"released_early_at"?: string | null,"spare_pages"?: number,"starts_at"?: string,"status"?: Database["public"]['Enums']["exam_status"],"subject_id"?: number,"title"?: string,"updated_at"?: string
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
"set_account_status_tx":
{ Args: { "p_action": string,"p_actor": string,"p_target": string }; Returns: string
                           },
"set_exam_paper_settings":
{ Args: { "p_exam": string,"p_exam_code": string,"p_reason"?: string,"p_release_minutes_before": number,"p_spare_pages": number }; Returns: Json
                           },
"set_exam_status":
{ Args: { "p_id": string,"p_status": Database["public"]['Enums']["exam_status"] }; Returns: Json
                           }
          }
          Enums: {
            "account_status": "unconfirmed"|"pending"|"profile_incomplete"|"active"|"suspended","app_role": "owner"|"admin"|"teacher"|"tutor"|"corrector"|"student"|"parent","attendance_status": "present"|"late"|"absent","booking_status": "awaiting_payment"|"paid"|"cancel_requested"|"refunded"|"part_refunded"|"cancelled"|"expired","exam_format": "in_person"|"online"|"both","exam_status": "draft"|"published"|"cancelled"|"completed","paper_download_kind": "home"|"print_pack"|"reprint"|"admin_preview","paper_kind": "paper"|"insert","sitting_mode": "centre"|"home","subject_kind": "school"|"entrance"
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
            "account_status": ["unconfirmed", "pending", "profile_incomplete", "active", "suspended"],"app_role": ["owner", "admin", "teacher", "tutor", "corrector", "student", "parent"],"attendance_status": ["present", "late", "absent"],"booking_status": ["awaiting_payment", "paid", "cancel_requested", "refunded", "part_refunded", "cancelled", "expired"],"exam_format": ["in_person", "online", "both"],"exam_status": ["draft", "published", "cancelled", "completed"],"paper_download_kind": ["home", "print_pack", "reprint", "admin_preview"],"paper_kind": ["paper", "insert"],"sitting_mode": ["centre", "home"],"subject_kind": ["school", "entrance"]
          }
        }
} as const
