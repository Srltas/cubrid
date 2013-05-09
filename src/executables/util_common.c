/*
 * Copyright (C) 2008 Search Solution Corporation. All rights reserved by Search Solution.
 *
 *   This program is free software; you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation; either version 2 of the License, or
 *   (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *
 */

/*
 * util_common.c - utility common functions
 */

#ident "$Id$"

#include <ctype.h>

#include "config.h"
#include "porting.h"
#include "utility.h"
#include "message_catalog.h"
#include "error_code.h"

#include "system_parameter.h"
#include "util_func.h"
#include "ini_parser.h"
#include "environment_variable.h"
#include "heartbeat.h"
#include "log_impl.h"
#if !defined(WINDOWS)
#include <fcntl.h>
#endif /* !defined(WINDOWS) */

typedef enum
{
  EXISTING_DATABASE,
  NEW_DATABASE
} DATABASE_NAME;

static int utility_get_option_index (UTIL_ARG_MAP * arg_map, int arg_ch);
static int check_database_name_local (const char *name,
				      int existing_or_new_db);
static char **util_split_ha_node (const char *str);
static char **util_split_ha_db (const char *str);
static char **util_split_ha_sync (const char *str);
static int util_get_ha_parameters (char **ha_node_list_p, char **ha_db_list_p,
				   char **ha_sync_mode_p,
				   char **ha_copy_log_base_p,
				   int *ha_max_mem_size_p);
static bool util_is_replica_node (void);
static int util_size_to_byte (double *pre, char post);

/*
 * utility_initialize() - initialize cubrid library
 *   return: 0 if success, otherwise -1
 */
int
utility_initialize ()
{
  if (msgcat_init () != NO_ERROR)
    {
      fprintf (stderr, "Unable to access system message catalog.\n");
      return ER_BO_CANNOT_ACCESS_MESSAGE_CATALOG;
    }

  return NO_ERROR;
}

/*
 * utility_get_generic_message() - get a string of the generic-utility from the catalog
 *   return: message string
 *   message_index(in): an index of the message string
 */
const char *
utility_get_generic_message (int message_index)
{
  return (msgcat_message (MSGCAT_CATALOG_UTILS,
			  MSGCAT_UTIL_SET_GENERIC, message_index));
}

/*
 * check_database_name() - check validation of the name of a database for existing db
 *   return: error code
 *   name(in): the name of a database
 */
int
check_database_name (const char *name)
{
  return check_database_name_local (name, EXISTING_DATABASE);
}

/*
 * check_database_name() - check validation of the name of a database for new db
 *   return: error code
 *   name(in): the name of a database
 */
int
check_new_database_name (const char *name)
{
  return check_database_name_local (name, NEW_DATABASE);
}

/*
 * check_database_name_local() - check validation of the name of a database
 *   return: error code
 *   name(in): the name of a database
 *   existing_or_new_db(in): whether db is existing or new one 
 */
static int
check_database_name_local (const char *name, int existing_or_new_db)
{
  int status = NO_ERROR;
  int i = 0;

  if (name[0] == '#')
    {
      status = ER_GENERIC_ERROR;
    }
  else
    {
      for (i = 0; name[i] != 0; i++)
	{
	  if (isspace (name[i]) || name[i] == '/' || name[i] == '\\'
	      || !isprint (name[i])
	      || (existing_or_new_db == NEW_DATABASE && name[i] == '@'))
	    {
	      status = ER_GENERIC_ERROR;
	      break;
	    }
	}
    }

  if (status == ER_GENERIC_ERROR)
    {
      const char *message =
	utility_get_generic_message (MSGCAT_UTIL_GENERIC_BAD_DATABASE_NAME);
      if (message != NULL)
	{
	  fprintf (stderr, message, name[i], name);
	}
    }
  return status;
}

/*
 * check_volume_name() - check validation of the name of a volume
 *   return: error code
 *   name(in): the name of a volume
 */
int
check_volume_name (const char *name)
{
  int status = NO_ERROR;
  int i = 0;

  if (name == NULL)
    {
      return NO_ERROR;
    }

  if (name[0] == '#')
    {
      status = ER_GENERIC_ERROR;
    }
  else
    {
      for (i = 0; name[i] != 0; i++)
	{
	  if (isspace (name[i]) || name[i] == '/' || name[i] == '\\'
	      || !isprint (name[i]))
	    {
	      status = ER_GENERIC_ERROR;
	      break;
	    }
	}
    }

  if (status == ER_GENERIC_ERROR)
    {
      const char *message =
	utility_get_generic_message (MSGCAT_UTIL_GENERIC_BAD_VOLUME_NAME);
      if (message != NULL)
	{
	  fprintf (stderr, message, name[i], name);
	}
    }
  return status;
}

/*
 * utility_get_option_index() - search an option in the map of arguments
 *   return: an index of a founded option
 *   arg_map(in): the map of arguments
 *   arg_ch(in): the value of an argument
 */
static int
utility_get_option_index (UTIL_ARG_MAP * arg_map, int arg_ch)
{
  int i;

  for (i = 0; arg_map[i].arg_ch; i++)
    {
      if (arg_map[i].arg_ch == arg_ch)
	{
	  return i;
	}
    }
  return -1;
}

/*
 * utility_get_option_int_value() - search an option in the map of arguments
 *      and return that value
 *   return: the value of a searched argument
 *   arg_map(in): the map of arguments
 *   arg_ch(in): the value of an argument
 */
int
utility_get_option_int_value (UTIL_ARG_MAP * arg_map, int arg_ch)
{
  int index = utility_get_option_index (arg_map, arg_ch);
  if (index != -1)
    {
      return arg_map[index].arg_value.i;
    }
  return 0;
}

/*
 * get_option_bool_value() - search an option in the map of arguments
 *      and return that value
 *   return: the value of a searched argument
 *   arg_map(in): the map of arguments
 *   arg_ch(in): the value of an argument
 */
bool
utility_get_option_bool_value (UTIL_ARG_MAP * arg_map, int arg_ch)
{
  int index = utility_get_option_index (arg_map, arg_ch);
  if (index != -1)
    {
      if (arg_map[index].arg_value.i == 1)
	{
	  return true;
	}
    }
  return false;
}

/*
 * get_option_string_value() - search an option in the map of arguments
 *      and return that value
 *   return: the value of a searched argument
 *   arg_map(in): the map of arguments
 *   arg_ch(in): the value of an argument
 */
char *
utility_get_option_string_value (UTIL_ARG_MAP * arg_map, int arg_ch,
				 int index)
{
  int arg_index = utility_get_option_index (arg_map, arg_ch);
  if (arg_index != -1)
    {
      if (arg_ch == OPTION_STRING_TABLE)
	{
	  if (index < arg_map[arg_index].value_info.num_strings)
	    {
	      return (((char **) arg_map[arg_index].arg_value.p)[index]);
	    }
	}
      else
	{
	  return ((char *) arg_map[arg_index].arg_value.p);
	}
    }
  return NULL;
}

int
utility_get_option_string_table_size (UTIL_ARG_MAP * arg_map)
{
  int arg_index = utility_get_option_index (arg_map, OPTION_STRING_TABLE);
  if (arg_index != -1)
    {
      return arg_map[arg_index].value_info.num_strings;
    }
  return 0;
}

/*
 * fopen_ex - open a file for variable architecture
 *    return: FILE *
 *    filename(in): path to the file to open
 *    type(in): open type
 */
FILE *
fopen_ex (const char *filename, const char *type)
{
#if defined(SOLARIS)
  size_t r = 0;
  char buf[1024];

  extern size_t confstr (int, char *, size_t);
  r = confstr (_CS_LFS_CFLAGS, buf, 1024);

  if (r > 0)
    return fopen64 (filename, type);
  else
    return fopen (filename, type);
#elif defined(HPUX)
#if _LFS64_LARGEFILE == 1
  return fopen64 (filename, type);
#else
  return fopen (filename, type);
#endif
#elif defined(AIX) || (defined(I386) && defined(LINUX))
  return fopen64 (filename, type);
#else /* NT, ALPHA_OSF, and the others */
  return fopen (filename, type);
#endif
}

/*
 * utility_keyword_search
 */
int
utility_keyword_search (UTIL_KEYWORD * keywords, int *keyval_p,
			char **keystr_p)
{
  UTIL_KEYWORD *keyp;

  if (*keyval_p >= 0 && *keystr_p == NULL)
    {
      /* get keyword string from keyword value */
      for (keyp = keywords; keyp->keyval >= 0; keyp++)
	{
	  if (*keyval_p == keyp->keyval)
	    {
	      *keystr_p = keyp->keystr;
	      return NO_ERROR;
	    }
	}
    }
  else if (*keyval_p < 0 && *keystr_p != NULL)
    {
      /* get keyword value from keyword string */
      for (keyp = keywords; keyp->keystr != NULL; keyp++)
	{
	  if (!strcasecmp (*keystr_p, keyp->keystr))
	    {
	      *keyval_p = keyp->keyval;
	      return NO_ERROR;
	    }
	}
    }
  return ER_FAILED;
}

/*
 * utility_localtime - transform date and time to broken-down time
 *    return: 0 if success, otherwise -1
 *    ts(in): pointer of time_t data value
 *    result(out): pointer of struct tm which will store the broken-down time
 */
int
utility_localtime (const time_t * ts, struct tm *result)
{
  struct tm *tm_p, tm_val;

  if (result == NULL)
    {
      return -1;
    }

  tm_p = localtime_r (ts, &tm_val);
  if (tm_p == NULL)
    {
      memset (result, 0, sizeof (struct tm));
      return -1;
    }

  memcpy (result, tm_p, sizeof (struct tm));
  return 0;
}

/*
 * util_is_localhost -
 *
 * return:
 *
 * NOTE:
 */
bool
util_is_localhost (char *host)
{
  char localhost[PATH_MAX];

  GETHOSTNAME (localhost, PATH_MAX);
  if (strcmp (host, localhost) == 0)
    {
      return true;
    }

  return false;
}

/*
 * util_get_num_of_ha_nodes - counter the number of nodes
 *      in either ha_node_list or ha_replica_list
 *    return: the number of nodes in a node list
 *    node_list(in): ha_node_list or ha_replica_list
 */
int
util_get_num_of_ha_nodes (const char *node_list)
{
  char **ha_node_list_pp = NULL;
  int num_of_nodes = 0;

  if (node_list == NULL)
    {
      return 0;
    }
  if ((ha_node_list_pp = util_split_ha_node (node_list)) != NULL)
    {
      for (num_of_nodes = 0; ha_node_list_pp[num_of_nodes] != NULL;)
	{
	  num_of_nodes++;
	}
    }

  if (ha_node_list_pp)
    {
      util_free_string_array (ha_node_list_pp);
    }

  return num_of_nodes;
}

static char **
util_split_ha_node (const char *str)
{
  char *start_node;

  start_node = strchr (str, '@');
  if (start_node == NULL || str == start_node)
    {
      return NULL;
    }

  return util_split_string (start_node + 1, " ,:");
}

static char **
util_split_ha_db (const char *str)
{
  return util_split_string (str, " ,:");
}

static char **
util_split_ha_sync (const char *str)
{
  return util_split_string (str, " ,:");
}

/*
 * copylogdb_keyword() - get keyword value or string of the copylogdb mode
 *   return: NO_ERROR or ER_FAILED
 *   keyval_p(in/out): keyword value
 *   keystr_p(in/out): keyword string
 */
int
copylogdb_keyword (int *keyval_p, char **keystr_p)
{
  static UTIL_KEYWORD keywords[] = {
    {LOGWR_MODE_ASYNC, "async"},
    {LOGWR_MODE_SEMISYNC, "semisync"},
    {LOGWR_MODE_SYNC, "sync"},
    {-1, NULL}
  };

  return utility_keyword_search (keywords, keyval_p, keystr_p);
}

/*
 * changemode_keyword() - get keyword value or string of the server mode
 *   return: NO_ERROR or ER_FAILED
 *   keyval_p(in/out): keyword value
 *   keystr_p(in/out): keyword string
 */
int
changemode_keyword (int *keyval_p, char **keystr_p)
{
  static UTIL_KEYWORD keywords[] = {
    {HA_SERVER_STATE_IDLE, HA_SERVER_STATE_IDLE_STR},
    {HA_SERVER_STATE_ACTIVE, HA_SERVER_STATE_ACTIVE_STR},
    {HA_SERVER_STATE_TO_BE_ACTIVE, HA_SERVER_STATE_TO_BE_ACTIVE_STR},
    {HA_SERVER_STATE_STANDBY, HA_SERVER_STATE_STANDBY_STR},
    {HA_SERVER_STATE_TO_BE_STANDBY, HA_SERVER_STATE_TO_BE_STANDBY_STR},
    {HA_SERVER_STATE_MAINTENANCE, HA_SERVER_STATE_MAINTENANCE_STR},
    {HA_SERVER_STATE_DEAD, HA_SERVER_STATE_DEAD_STR},
    {-1, NULL}
  };

  return utility_keyword_search (keywords, keyval_p, keystr_p);
}

static int
util_get_ha_parameters (char **ha_node_list_p, char **ha_db_list_p,
			char **ha_sync_mode_p, char **ha_copy_log_base_p,
			int *ha_max_mem_size_p)
{
  int error = NO_ERROR;

  *(ha_db_list_p) = prm_get_string_value (PRM_ID_HA_DB_LIST);
  if (*(ha_db_list_p) == NULL || **(ha_db_list_p) == '\0')
    {
      const char *message =
	utility_get_generic_message (MSGCAT_UTIL_GENERIC_INVALID_PARAMETER);
      fprintf (stderr, message, prm_get_name (PRM_ID_HA_DB_LIST), "");
      return ER_GENERIC_ERROR;
    }

  *(ha_node_list_p) = prm_get_string_value (PRM_ID_HA_NODE_LIST);
  if (*(ha_node_list_p) == NULL || **(ha_node_list_p) == '\0')
    {
      const char *message =
	utility_get_generic_message (MSGCAT_UTIL_GENERIC_INVALID_PARAMETER);
      fprintf (stderr, message, prm_get_name (PRM_ID_HA_NODE_LIST), "");
      return ER_GENERIC_ERROR;
    }

  *(ha_sync_mode_p) = prm_get_string_value (PRM_ID_HA_COPY_SYNC_MODE);
  *(ha_max_mem_size_p) = prm_get_integer_value (PRM_ID_HA_APPLY_MAX_MEM_SIZE);

  *(ha_copy_log_base_p) = prm_get_string_value (PRM_ID_HA_COPY_LOG_BASE);
  if (*(ha_copy_log_base_p) == NULL || **(ha_copy_log_base_p) == '\0')
    {
      *(ha_copy_log_base_p) = envvar_get ("DATABASES");
      if (*(ha_copy_log_base_p) == NULL)
	{
	  *(ha_copy_log_base_p) = ".";
	}
    }

  return error;
}

static bool
util_is_replica_node (void)
{
  bool is_replica_node = false;
  int i;
  char local_host_name[MAXHOSTNAMELEN];
  char *ha_replica_list_p, **ha_replica_list_pp = NULL;

  ha_replica_list_p = prm_get_string_value (PRM_ID_HA_REPLICA_LIST);
  if (ha_replica_list_p != NULL && *(ha_replica_list_p) != '\0')
    {
      ha_replica_list_pp = util_split_ha_node (ha_replica_list_p);
      if (ha_replica_list_pp != NULL
	  && (GETHOSTNAME (local_host_name, sizeof (local_host_name)) == 0))
	{
	  for (i = 0; ha_replica_list_pp[i] != NULL; i++)
	    {
	      if (strcmp (ha_replica_list_pp[i], local_host_name) == 0)
		{
		  is_replica_node = true;
		  break;
		}
	    }

	}
    }

  if (ha_replica_list_pp)
    {
      util_free_string_array (ha_replica_list_pp);
    }

  return is_replica_node;
}

/*
 * util_free_ha_conf -
 *
 * return:
 *
 * NOTE:
 */
void
util_free_ha_conf (HA_CONF * ha_conf)
{
  int i;
  HA_NODE_CONF *nc;

  for (i = 0, nc = ha_conf->node_conf; i < ha_conf->num_node_conf; i++)
    {
      if (nc[i].node_name)
	{
	  free_and_init (nc[i].node_name);
	}

      if (nc[i].copy_log_base)
	{
	  free_and_init (nc[i].copy_log_base);
	}

      if (nc[i].copy_sync_mode)
	{
	  free_and_init (nc[i].copy_sync_mode);
	}
    }
  free_and_init (ha_conf->node_conf);
  ha_conf->num_node_conf = 0;
  ha_conf->node_conf = NULL;

  if (ha_conf->db_names)
    {
      util_free_string_array (ha_conf->db_names);
      ha_conf->db_names = NULL;
    }

  return;
}

/*
 * util_make_ha_conf -
 *
 * return:
 *
 * NOTE:
 */
int
util_make_ha_conf (HA_CONF * ha_conf)
{
  int error = NO_ERROR;
  int i, num_ha_nodes;
  char *ha_db_list_p = NULL;
  char *ha_node_list_p = NULL, **ha_node_list_pp = NULL;
  char *ha_sync_mode_p = NULL, **ha_sync_mode_pp = NULL;
  char *ha_copy_log_base_p;
  int ha_max_mem_size;
  bool is_replica_node;

  error =
    util_get_ha_parameters (&ha_node_list_p, &ha_db_list_p, &ha_sync_mode_p,
			    &ha_copy_log_base_p, &ha_max_mem_size);
  if (error != NO_ERROR)
    {
      return error;
    }

  ha_conf->db_names = util_split_ha_db (ha_db_list_p);
  if (ha_conf->db_names == NULL)
    {
      const char *message =
	utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
      fprintf (stderr, message);

      error = ER_GENERIC_ERROR;
      goto ret;
    }

  ha_node_list_pp = util_split_ha_node (ha_node_list_p);
  if (ha_node_list_pp == NULL)
    {
      const char *message =
	utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
      fprintf (stderr, message);

      error = ER_GENERIC_ERROR;
      goto ret;
    }

  for (i = 0; ha_node_list_pp[i] != NULL;)
    {
      i++;
    }
  num_ha_nodes = i;

  ha_conf->node_conf =
    (HA_NODE_CONF *) malloc (sizeof (HA_NODE_CONF) * num_ha_nodes);
  if (ha_conf->node_conf == NULL)
    {
      const char *message =
	utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
      fprintf (stderr, message);

      error = ER_GENERIC_ERROR;
      goto ret;
    }
  memset ((void *) ha_conf->node_conf, 0,
	  sizeof (HA_NODE_CONF) * num_ha_nodes);
  ha_conf->num_node_conf = num_ha_nodes;

  /* set ha_sync_mode */
  is_replica_node = util_is_replica_node ();
  if (is_replica_node == true)
    {
      for (i = 0; i < num_ha_nodes; i++)
	{
	  ha_conf->node_conf[i].copy_sync_mode = strdup ("async");
	  if (ha_conf->node_conf[i].copy_sync_mode == NULL)
	    {
	      const char *message =
		utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
	      fprintf (stderr, message);

	      error = ER_GENERIC_ERROR;
	      goto ret;
	    }
	}
    }
  else
    {
      if (ha_sync_mode_p == NULL || *(ha_sync_mode_p) == '\0')
	{
	  for (i = 0; i < num_ha_nodes; i++)
	    {
	      ha_conf->node_conf[i].copy_sync_mode = strdup ("sync");
	      if (ha_conf->node_conf[i].copy_sync_mode == NULL)
		{
		  const char *message =
		    utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
		  fprintf (stderr, message);

		  error = ER_GENERIC_ERROR;
		  goto ret;
		}
	    }
	}
      else
	{
	  int mode;

	  ha_sync_mode_pp = util_split_ha_sync (ha_sync_mode_p);
	  if (ha_sync_mode_pp == NULL)
	    {
	      const char *message =
		utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
	      fprintf (stderr, message);

	      error = ER_GENERIC_ERROR;
	      goto ret;
	    }

	  for (i = 0; i < num_ha_nodes; i++)
	    {
	      mode = -1;
	      if (ha_sync_mode_pp[i] == NULL ||
		  copylogdb_keyword (&mode, &ha_sync_mode_pp[i]) == -1)
		{
		  const char *message =
		    utility_get_generic_message
		    (MSGCAT_UTIL_GENERIC_INVALID_PARAMETER);

		  fprintf (stderr, message,
			   prm_get_name (PRM_ID_HA_COPY_SYNC_MODE),
			   (ha_sync_mode_pp[i]) ? ha_sync_mode_pp[i] : "");

		  error = ER_GENERIC_ERROR;
		  goto ret;
		}

	      ha_conf->node_conf[i].copy_sync_mode =
		strdup (ha_sync_mode_pp[i]);
	      if (ha_conf->node_conf[i].copy_sync_mode == NULL)
		{
		  const char *message =
		    utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
		  fprintf (stderr, message);

		  error = ER_GENERIC_ERROR;
		  goto ret;
		}
	    }
	}
    }

  for (i = 0; i < num_ha_nodes; i++)
    {
      assert_release (ha_node_list_pp[i] != NULL);

      ha_conf->node_conf[i].node_name = strdup (ha_node_list_pp[i]);
      ha_conf->node_conf[i].copy_log_base = strdup (ha_copy_log_base_p);
      ha_conf->node_conf[i].apply_max_mem_size = ha_max_mem_size;

      if (ha_conf->node_conf[i].node_name == NULL
	  || ha_conf->node_conf[i].copy_log_base == NULL)
	{
	  const char *message =
	    utility_get_generic_message (MSGCAT_UTIL_GENERIC_NO_MEM);
	  fprintf (stderr, message);

	  error = ER_GENERIC_ERROR;
	  goto ret;
	}
    }

ret:
  if (ha_node_list_pp)
    {
      util_free_string_array (ha_node_list_pp);
      ha_node_list_pp = NULL;
    }

  if (ha_sync_mode_pp)
    {
      util_free_string_array (ha_sync_mode_pp);
      ha_sync_mode_pp = NULL;
    }

  if (error != NO_ERROR)
    {
      util_free_ha_conf (ha_conf);
    }

  return error;
}

/*
 * util_get_ha_mode_for_sa_utils - 
 * 
 * return:
 *
 * NOTE:
 */
int
util_get_ha_mode_for_sa_utils (void)
{
  return prm_get_integer_value (PRM_ID_HA_MODE_FOR_SA_UTILS_ONLY);
}

#if !defined(WINDOWS)
/*
 * util_redirect_stdout_to_null - redirect stdout/stderr to /dev/null
 *
 * return:
 *
 */
void
util_redirect_stdout_to_null (void)
{
  const char *null_dev = "/dev/null";
  int fd;

  fd = open (null_dev, O_WRONLY);
  if (fd != -1)
    {
      close (1);
      close (2);
      dup2 (fd, 1);
      dup2 (fd, 2);
      close (fd);
    }
}
#endif /* !defined(WINDOWS) */

/*
 * util_size_to_byte -
 *
 * return:
 *
 */
static int
util_size_to_byte (double *pre, char post)
{
  switch (post)
    {
    case 'b':
    case 'B':
      /* bytes */
      break;
    case 'k':
    case 'K':
      /* kilo */
      *pre = *pre * 1024.0;
      break;
    case 'm':
    case 'M':
      /* mega */
      *pre = *pre * 1048576.0;
      break;
    case 'g':
    case 'G':
      /* giga */
      *pre = *pre * 1073741824.0;
      break;
    case 't':
    case 'T':
      /* tera */
      *pre = *pre * 1099511627776.0;
      break;
    case 'p':
    case 'P':
      /* peta */
      *pre = *pre * 1125899906842624.0;
      break;
    default:
      return ER_FAILED;
    }

  return NO_ERROR;
}

/*
 * util_byte_to_size_string -
 *
 * return:
 *
 */
int
util_byte_to_size_string (UINT64 size_num, char *buf, size_t len)
{
  const char *ss = "BKMGTP";
  double v = (double) size_num;
  int pow = 0;

  if (buf == NULL)
    {
      return ER_FAILED;
    }

  while (pow < 6 && v >= 1024.0)
    {
      pow++;
      v /= 1024.0;
    }

  if (snprintf (buf, len, "%.1f%c", v, ss[pow]) < 0)
    {
      return ER_FAILED;
    }

  return NO_ERROR;
}

/*
 * util_size_string_to_byte -
 *
 * return:
 *
 */
int
util_size_string_to_byte (const char *size_str, UINT64 * size_num)
{
  int len;
  double val;
  char c = 'B';
  char *end;

  if (size_str == NULL)
    {
      return ER_FAILED;
    }
  len = strlen (size_str);

  val = strtod (size_str, &end);
  if (end == size_str)
    {
      return ER_FAILED;
    }

  if (isalpha (*end))
    {
      c = *end;
      end += 1;
    }

  if (end != (size_str + len) || util_size_to_byte (&val, c) != NO_ERROR)
    {
      return ER_FAILED;
    }

  *size_num = (UINT64) val;
  *size_num /= 1024ULL;
  *size_num *= 1024ULL;
  return NO_ERROR;
}

/*
 * util_print_deprecated -
 *
 * return:
 *
 */
void
util_print_deprecated (const char *option)
{
  int cat = MSGCAT_CATALOG_UTILS;
  int set = MSGCAT_UTIL_SET_GENERIC;
  int msg = MSGCAT_UTIL_GENERIC_DEPRECATED;
  const char *fmt = msgcat_message (cat, set, msg);
  if (fmt == NULL)
    {
      fprintf (stderr, "error: msgcat_message");
    }
  else
    {
      fprintf (stderr, fmt, option);
    }
}
